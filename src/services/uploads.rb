class App::Services::Uploads < App::Services::Base
  # Issue a presigned S3 PUT URL for a direct browser upload — but only when AWS
  # is actually configured. When it isn't, we return `configured: false` so the
  # client falls back to storing the image inline (a data: URL). This lets photo
  # upload work with zero infra today and switch to S3 the moment creds are set,
  # with no frontend or schema change.
  def presign
    return return_success(configured: false) unless s3_configured?

    content_type = params[:content_type].to_s
    return_errors!('Only image uploads are allowed', 400) unless content_type.start_with?('image/')

    ext    = content_type.split('/').last.gsub(/[^a-z0-9]/i, '')
    key    = "uploads/#{current_client_id}/#{SecureRandom.uuid}.#{ext}"
    bucket = ENV['AWS_S3_BUCKET']

    require 'aws-sdk-s3'
    signer = Aws::S3::Presigner.new(client: s3_client)
    upload_url = signer.presigned_url(
      :put_object, bucket: bucket, key: key,
      content_type: content_type, expires_in: 300
    )

    public_base = ENV['AWS_S3_PUBLIC_BASE'].to_s
    public_url  = public_base.empty? ?
      "https://#{bucket}.s3.#{ENV['AWS_REGION'] || 'ap-south-1'}.amazonaws.com/#{key}" :
      "#{public_base.chomp('/')}/#{key}"

    return_success(configured: true, upload_url: upload_url, public_url: public_url, key: key)
  rescue => e
    App.logger.error("presign failed: #{e.class}: #{e.message}")
    # Never hard-fail the form — let the client fall back to inline storage.
    return_success(configured: false)
  end

  private

  def s3_configured?
    %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_S3_BUCKET].none? { |k| ENV[k].to_s.empty? }
  end

  def s3_client
    require 'aws-sdk-s3'
    Aws::S3::Client.new(
      region: ENV['AWS_REGION'] || 'ap-south-1',
      access_key_id: ENV['AWS_ACCESS_KEY_ID'],
      secret_access_key: ENV['AWS_SECRET_ACCESS_KEY']
    )
  end
end
