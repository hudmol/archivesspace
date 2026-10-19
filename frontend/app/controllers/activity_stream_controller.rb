class ActivityStreamController < ApplicationController
  # FIXME permissions
  set_access_control 'view_repository' => [:admin,
                                           :exports,
                                           :export_create,
                                           :export_download]

  def admin
  end

  def exports
    @object_types = JSONModel::HTTP.get_json('/activity-stream/object_types').map{|uri| uri.split('/').last}
    @search_data = JSONModel(:activity_stream_export).all(
      page: [Integer(params[:page] || 1), 1].max,
      page_size: 50,
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
      flash[:success] = "Export created successfully. Once complete the download will be available from this page."
      render :json => {:status => "SUCCESS"}
    else
      render :json => {:status => "ERROR"}
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
end