
# Audit Table Activity Stream Development Notes

This branch (`audit-table-activity-stream`) contains the implementation of the
requirements specified in the following documents:

- Request for Comment - ASpace Activity Stream + Audit Table - Public (9/17/2025)
- Activity Stream Scope Statement (2/2/2026)

The implementation was also informed by a number of calls.

The branch is currently based on ArchivesSpace v4.2.1.

This document summarizes the technical design and motivations for key design
decisions. It also provides some guidance on configuration and testing.


## Database migrations

There are database migrations required for this functionality. The migrations
add new tables. No existing table definitions or data are changed by the
migrations. The new tables are:
```
audit_enabled_tracking
audit_event
audit_export
audit_page
audit_page_lock
audit_record
```


## Configuration

Some configuration is required. The following snippet shows the new lines added
to `common/config/config-defaults.rb`:

```
# Audit logging disabled by default
AppConfig[:enable_audit_logging] = false
# When true, render uris as root-relative in the activity stream API
# Default is to render full uris including scheme, host, etc
AppConfig[:activity_stream_use_relative_uris] = false
# Some object types are opt-in for audit logging
# This array holds their jsonmodel names as strings
# Supported optional types:
#   accession, location, assessment, permission, group, user
AppConfig[:audit_logging_include_object_types] = []
```

A minimal configuration that enables audit logging:
```
AppConfig[:enable_audit_logging] = true
```

## Endpoints

All endpoints for the Activity Stream API are GETs. There are currently no
permissions required to hit these endpoints.
```
/activity-stream
/activity-stream/page/:page
/activity-stream/:object_type
/activity-stream/:object_type/page/:page
/activity-stream/object_types
/activity-stream/event/:id
```

## Supported Object Types

Most top level ArchivesSpace models are supported by default. Here is the
current list:
```
repository
agent_person
agent_family
agent_corporate_entity
agent_software
resource
archival_object
digital_object
digital_object_component
top_container
container_profile
subject
classification
```

There are a number of ArchivesSpace models that are not included by default, but
can be included via configuration. They are:
```
accession
location
assessment
permission
group
user
```

An example config might look like this:
```
AppConfig[:audit_logging_include_object_types] = ['accession', 'user', 'group']
```

To find the Object Types supported for an ArchivesSpace instance, hit this
endpoint:
```
GET /activity-stream/object_types
```


## Event Logging

Individual audit events are created by calls to `AuditEvent#log_event`. These
calls are currently made in the following files:
```
backend/app/model/ASModel_crud.rb
backend/app/model/enumeration.rb
backend/app/model/mixins/relationships.rb
backend/app/model/mixins/tree_nodes.rb
backend/app/model/top_container.rb
backend/app/lib/component_transfer.rb
backend/app/model/ASModel_transfers.rb
```
Each call to `AuditEvent#log_event` will result in zero or one rows being
inserted into `audit_event` and, if an event is inserted, then one or more
rows will be inserted into `audit_record` - one row for each affected record.

When an event is logged, its `change_method` is passed via the `RequestContext`.
When the request originates from the staff ui, the change method is passed to
the backend via a header called `HTTP_X_ARCHIVESSPACE_CHANGE_METHOD` and then
placed in the `RequestContext`.


## Pagination and activity storage

When a client is consuming an activity stream, most requests involve
fetching an ordered page of activities.  For the API to work in
practice, it must be efficient for a client to fetch any given page.
There are several considerations here:

  * The number of recorded activities grows without bound and clients
    will fetch larger and larger page numbers over time.

  * Some user or system actions will require many activities to be
    recorded at once.

  * Database storage is at a premium.

These considerations, and their relationship to the technical design,
are covered in the following sub-sections.

### Managing growing numbers of activities

Pagination in relational databases can be deceptive: every major
database provides `LIMIT`, `OFFSET` and `ORDER BY`, which seem perfect
for implementing pagination, but their performance isn't acceptable
for large datasets.  Because `LIMIT` and `OFFSET` work by producing
the first *offset+limit* rows and then discarding all but the last
*limit* of them, each page is more expensive to produce than the one
that came before it.  As a result, page 100 takes around twice as long
to produce as page 50.

This is a particularly bad fit for activity streams, because
activities will accrue over time (and potentially in very large
numbers), while clients will primarily be requesting pages near the
end of the range (i.e. the most expensive pages to produce).

To avoid these issues, we pre-group events into pages using the
`audit_page` table.  Each row in this table represents a page of
activities available through the API for a given activity stream.  An
`audit_page` row has information such as:

  * the page number

  * the activity stream

  * the type of events contained in the page (either 'audit' or
    'bulk'; more on this below)

  * whether the page has been fully written

  * a packed set of IDs sufficient to render the page

There are two main benefits to this approach:

  * It allows for constant-time lookups for any given page.
    Responding to a request for a page within an activity stream just
    requires a lookup of `audit_page`, and then lookups to pull back
    the specific events, but these are all simple (indexed) queries.

  * It gives flexibility over where the actual event data is stored,
    which is important for bulk record creation and record archiving
    (more on this below).

There are also some consequences of this design:

  * Pages have a fixed maximum size, and so we try to strike a balance
    between a size that is small enough for an API consumer to consume
    but large enough to reduce database storage overhead.  Currently
    this number is 500 activities, but this can be tuned if required.

  * The last page in any activity stream will be continuously
    rewritten until it reaches the maximum number of entries, and then
    closed off once full.  A client fetching the last page needs to
    handle the fact that it may be incomplete (by looking for the
    presence of a `next` page entry).


### Recording activities in bulk

Some update actions from within ArchivesSpace can result in a large
number of activity stream events.  An extreme example is database
migrations, which can potentially update every record across all
repositories, but user-initiated activities such as changes to
controlled value lists or updates to certain record types can have
effects of a similar scale.  It may be necessary to create thousands
or even millions of activities in response to these kinds of actions.

Ordinarily, activities are logged one at a time into the `audit_event`
and `audit_record` tables.  These tables are designed to be as
space-efficient as possible, but inserting one row per activity risks
being unacceptably slow if generating millions of activities.
Different installations have differing levels of database latency and
insert performance but, even in the most optimistic case, inserting
one million rows is likely to take several minutes.

To avoid these overheads, we handle inserting activities in bulk in a
different way to regular activities.  Although bulk activities are
more numerous, they also tend to be structurally simpler.  Generally
they be expressed:

  * as one specific person;

  * performing one specific activity;

  * on a large number of records;

  * of one specific record type;

  * at one specific moment in time.

We can take advantage of this simpler structure to store bulk
activities in a way that doesn't require inserting one database row
per activity.  Instead, we insert pages straight into `audit_page`
(described above), where each page is marked as a `bulk` page,
augmented with the properties common to all activities in that page,
and whose packed set of IDs refers to the original record IDs that are
the subjects of the activities.  When a page is requested, we
reconstruct the representation of the activities from this structure.

The benefits of this approach:

  * We can generate millions of activities in seconds rather than
    minutes.

  * We can store millions of activities much more efficiently--in the
    realm of a few hundred kilobytes of database storage per million
    activities.

Some consequences of this design:

  * Pages of activities presented through the API may not always be
    evenly sized.  This was already true before, because the last page
    can always be incomplete, but bulk activities relax things even
    further: a page will always have at least 1 entry, and will never
    exceed the page size, but the specific number of entries may vary.

    To see the reason this happens, consider the following scenario:

      - Three ordinary activities are logged during normal
        ArchivesSpace operation.  These are added to page 5 of the
        activity stream, which is currently the last page in the
        stream.

      - Now some kind of batch action needs to record one million
        activities for updates to archival objects.  Because
        batch actions are represented as special entries in the
        `audit_page` table, they must be inserted as new pages (the
        first being page 6).

    We're left with two options:

      - Either we mark page 5 as completed, then start inserting the
        new bulk pages starting from page 6.

      - Or, we start inserting bulk pages from page 6, but somehow
        "pretend" they don't exist until page 5 has finished filling
        out with regular events (hiding the new pages from the API).

    The second option doesn't seem feasible, because we don't know how
    long it will take for page 5 to fill with regular events--it might
    be hours or days until enough events arrive to fill that page.  It
    also creates the strange scenario where page 5 would contain
    events that happened *after* the events of page 6, which is maybe
    not a crime but it sure feels like one.

    So, we just allow the page sizes to vary, which they were always
    going to anyway.  Callers can rely on the `next` page entry to
    know if another page is ready to read, and still rely on the page
    limit controlling the maximum number of activities they'll get per
    page.


  * Bulk activity identifiers use a different ID scheme

    Since ordinary activities have a row in the database, they can be
    referenced using their identifier, like:

         https://example.com/activity-stream/event/18852

    But bulk activity entries have no such ID (and storing one ID per
    activity would be prohibitively expensive anyway).  So, they
    instead use a different identifier scheme:

         https://example.com/activity-stream/event/_blk_p40o498

    Fetching a single activity works the same in either case, and since
    API consumers are expected to treat identifiers as opaque anyway,
    the difference shouldn't matter.

    But for the curious: the bulk identifier scheme just identifies
    the activity by the page it appears on and its position on the
    page.  These activity IDs are also normalized, so if the same
    activity appears in different activity streams, it will report the
    same canonical ID.


### Managing database storage

Another concern for an ever-growing set of activities is the space
required for MySQL to store them all.  Although bulk activities don't
take much space, a steady trickle of regular activities will use
increasing amounts of space over time in the `audit_event` and
`audit_record` tables.

To manage this, pages of activities can be archived.  When a page is
archived, its underlying events are packed into a aggregated value,
compressed, and written as a blob directly into the `audit_page`
table.  The underlying events are then removed from the `audit_event`
and `audit_record` tables.

Archiving is switched off by default, but you can enable it with a
`config.rb` setting like:

     AppConfig[:audit_logging_archive_threshold] = 1000

The `audit_logging_archive_threshold` setting controls how many
activity stream pages will be kept *unarchived* at any given time.  So
setting a value of 1000 (as above) would leave alone the 1,000 most
recently written pages and archive all other pages.  If you set the
value to zero:

     AppConfig[:audit_logging_archive_threshold] = 0

Then pages will be archived as soon as possible (that is, each page
will be archived as soon as it is closed off).  Finally, you can
disable archiving by setting the value to `nil` (the default):

     AppConfig[:audit_logging_archive_threshold] = nil

From the point of view of the consumer of the API, archiving is
completely transparent: the representation of activities doesn't
change--it's purely a storage optimization at the database level.
Archiving a page of activities should reduce the storage required by
about 95%, and our testing suggests that storing 100 million archived
events should consume about 350MB of database storage.

## Audit logging and Database Migrations

We investigated enforing the logging of audit events in database migrations.
We discovered that, while it is technically feasible, the burden on people
writing migrations is unnecessarily onerous, and the potential for error is
significant.

As a result the decision is to not require audit logging in database migrations.
Instead, there is a facility, in the staff UI, to generate a complete set of
bulk audit events by object type, or for all object types. This allows users
with the necessary permissions to trigger a resync from external systems thus
picking up any changes from a database migration.
