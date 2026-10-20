class Tombstone < Sequel::Model(:deleted_records)

  def before_save
    super

    self.timestamp = Time.now
    self.operator = RequestContext.get(:current_username)
    self.record_id = self.uri.gsub(%r{.*/}, '').to_i
  end

end
