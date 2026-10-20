class ActivityStreamExportRunner < JobRunner
  register_for_job_type('activity_stream_export_job',
                        create_permissions: [:view_activity_stream],
                        cancel_permissions: [:view_activity_stream],
                        hidden: true)

  def run
    file = nil
    begin
      RequestContext.open(:repo_id => @job.repo_id) do
        @job.write_output("Generating Activity Stream Export")
        file = ASUtils.tempfile('activity_stream_export_job_')

        export = ActivityStreamExport[:job_id => @job.id]
        export.running!

        export.write_csv(file)

        file.rewind
        @job.write_output("Adding activity stream export file.")

        export.complete!(@job.file_store.store(file))

        self.success!
      end
    rescue Exception => e
      @job.write_output(e.message)
      @job.write_output(e.backtrace)

      ActivityStreamExport[:job_id => @job.id].errored!

      raise e
    ensure
      if file
        file.close
        file.unlink
      end

      @job.write_output("Done.")
    end
  end
end
