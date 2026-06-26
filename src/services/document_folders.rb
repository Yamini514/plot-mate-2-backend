class App::Services::DocumentFolders < App::Services::Base
  # Folders for the document vault (tenant-scoped, optionally nested).
  def model = DocumentFolder

  def list
    return_success(scoped.order(:name).all.map(&:as_pos))
  end

  def create
    validate!('name' => App::Validate.text(params[:name], min: 1, max: 80, label: 'Folder name'))
    obj = DocumentFolder.new(client_id: current_client_id, name: params[:name].to_s.strip,
                             parent_id: params[:parent_id], created_by: App.cu.id)
    save(obj) { |f| return_success(f.as_pos) }
  end

  def delete
    # Detach documents in this folder (back to root) before removing it.
    Document.where(client_id: current_client_id, folder_id: item.id).update(folder_id: nil)
    DocumentFolder.where(client_id: current_client_id, parent_id: item.id).update(parent_id: nil)
    item.destroy
    return_success(deleted: true)
  end

  def item(id = rp[:id]) = (@item ||= scoped[id] || return_errors!('Folder not found', 404))
end
