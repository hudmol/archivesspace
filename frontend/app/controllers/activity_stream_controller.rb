class ActivityStreamController < ApplicationController
  set_access_control 'view_activity_stream' => [:exports,
                                                :export_create,
                                                :export_download,
                                                :poll_for_completed_exports]
  set_access_control 'manage_activity_stream' => [:admin,
                                                  :resync_feed,
                                                  :clear_exports]

  def admin
    @object_types = JSONModel::HTTP.get_json('/activity-stream/object_types').map{|uri| uri.split('/').last}
  end

  def exports
    @object_types = JSONModel::HTTP.get_json('/activity-stream/object_types').map{|uri| uri.split('/').last}
    @exports_running = !JSONModel::HTTP.get_json('/activity-stream-export/poll-for-completed').fetch('all_exports_completed')
    @search_data = JSONModel(:activity_stream_export).all(
      page: [Integer(params[:page] || 1), 1].max,
      page_size: 10,
      sort_field: params.fetch(:sort, :username),
      sort_direction: params.fetch(:direction, :asc),
      'resolve[]': ['criteria::user', 'criteria::repository', 'criteria::resource'],
    )
  end

  def export_create
    params[:criteria].delete('_resolved')

    response =
      JSONModel::HTTP.post_json(
        URI("#{JSONModel::HTTP.backend_url}/repositories/#{session[:repo_id]}/activity-stream-export/create?export_type=#{params[:export_type]}"),
        params[:criteria].to_json)

    if response.code == '200'
      flash[:success] = I18n.t('activity_stream._frontend.messages.export_created')
      render :json => {:status => "SUCCESS"}
    else
      error_data = ASUtils.json_parse(response.body).fetch('error', "Unknown error") rescue response.body
      render :json => {:status => "ERROR", :error => error_data}
    end
  end

  def export_download
    export = JSONModel(:activity_stream_export).find(params[:id])

    if export.status == 'EXPORT_STATUS_COMPLETE'
      self.response.headers['Content-Type'] = 'text/csv'
      self.response.headers['Content-Disposition'] = "attachment; filename=#{export.export_type}.csv"
      self.response.headers['Last-Modified'] = Time.now.ctime

      self.response_body = Enumerator.new do |stream|
        JSONModel::HTTP.stream("/activity-stream-export/#{params[:id]}/download") do |response|
          response.read_body do |chunk|
            stream << chunk
          end
        end
      end
    else
      raise RecordNotFound.new
    end
  end

  def resync_feed
    response = JSONModel::HTTP.post_form("/activity-stream/resync_feed", 'object_type[]' => params[:object_type])
    if response.code == '200'
      flash[:success] = I18n.t('activity_stream._frontend.messages.resync_feed_success')
    else
      flash[:error] = I18n.t('activity_stream._frontend.messages.resync_feed_error')
    end

    redirect_to :action => :admin
  end

  def poll_for_completed_exports
    response = JSONModel::HTTP.get_json("/activity-stream-export/poll-for-completed")
    render :json => response
  end

  def clear_exports
    response = JSONModel::HTTP.post_form("/activity-stream-export/clear-all")
    if response.code == '200'
      flash[:success] = I18n.t('activity_stream._frontend.messages.clear_exports_success')
    else
      flash[:error] = I18n.t('activity_stream._frontend.messages.clear_exports_error')
    end

    redirect_to :action => :exports
  end
end