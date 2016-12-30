class PushController < ApplicationController

  # BASE_URL = 'http://localhost:3000/api/'.freeze
  BASE_URL = 'https://api.follow-apps.com/api/'.freeze
  CAMPAIGN_NAME = 'Heroku demo transac'.freeze

  # get all the data required for showing the default page
  def index
    ensure_salesforce_connector
    fetch_app_and_key
    fetch_certificate if @mobile_app.present?
    fetch_users if @certificate.present?

    flash[:error_message] ||= @error_message
    flash[:info] ||= @info
  end

  # create the app and its API key
  def create
    @mobile_app = create_app
    if @mobile_app.present? && @mobile_app['identifier'].present?
      @api_key = create_api_key @mobile_app['identifier']
    end
    redirect_to "/", flash: { error_message: @error_message }
  end

  # revoke the certificate to allow sending a new one
  def destroy_certificate
    revoke_app_cert(params[:app_identifier], params[:cert_identifier])
    redirect_to "/", flash: { error_message: @error_message }
  end

  # send a push certificate
  def create_certificate
    create_app_cert(params['app_identifier'], params['cert'], params['pkey'])
    redirect_to "/", flash: { error_message: @error_message }
  end

  # send a push message to select users
  def send_push
    ensure_transac_campaign(params[:app_identifier])
    send_transac_push(params[:message], params[:customer_ids])
    redirect_to "/", flash: { error_message: @error_message, info: @info }
  end

  protected

  def ensure_salesforce_connector
    response = RestClient.get(url('crm_systems'), headers)
    result = JSON.parse response.body
    if !result['success']
      @error_message = "Could not fetch the campaigns"
    else
      @crm_system = result['result']['crm_systems'].find { |crm| crm['crm_type'] == 'sf' && crm['username'] == ENV['SALESFORCE_LOGIN'] }
    end

    if !@crm_system
      p ENV
      if ENV['SALESFORCE_LOGIN'].blank? || ENV['SALESFORCE_PASSWORD'].blank? ||
      ENV['SALESFORCE_TOKEN'].blank? || ENV['SALESFORCE_APP_CLIENT_ID'].blank? || ENV['SALESFORCE_APP_CLIENT_SECRET'].blank?
        @error_message = "The Salesforce connection can't be established, at least one of the 5 required ENV variables is missing."
      else
        # create the crm system
        post_params = {
          'name' => 'Insurance Demo Salesforce CRM',
          'username' => ENV['SALESFORCE_LOGIN'],
          'password' => ENV['SALESFORCE_PASSWORD'],
          'token' => ENV['SALESFORCE_TOKEN'],
          'client_id' => ENV['SALESFORCE_APP_CLIENT_ID'],
          'client_secret' => ENV['SALESFORCE_APP_CLIENT_SECRET'],
          'crm_type' => 'sf',
          'default_key_field' => 'email'
        }
        @crm_system = create_object(url('crm_systems'), post_params)
      end
    end
  end

  def fetch_app_and_key
    begin
      response = RestClient.get(url('apps'), headers)
    rescue RestClient::Unauthorized, RestClient::Forbidden => err
      @error_message = "You are not authorized, make sure your FOLLOWANALYTICS_API_TOKEN variable is defined and that your FollowAnalytics account works"
    rescue RestClient::ExceptionWithResponse => e
      @error_message = e.body
    end

    if response
      result = JSON.parse response.body
      if !result['success']
        @error_message = "Could not fetch the apps from your FollowAnalytics account"
      else
        @mobile_app = result['result']['apps'].find { |app| app['package_name'] == mobile_app_package_name }
        if @mobile_app
          response = RestClient.get(url('apps/' + @mobile_app['identifier'] + '/api_keys'), headers)
          result = JSON.parse response.body
          if !result['success']
            @error_message = "Could not fetch the API key related to your app"
          elsif result['result']['api_keys'].count < 1
            # if for some reason no API key is found, let's create one
            @api_key = create_api_key @mobile_app['identifier']
          else
            @api_key = result['result']['api_keys'].first
          end
        end
      end
    end
  end

  def fetch_users
    response = RestClient.get(url('customer_profiles?customer_id_type=user_id&num_per_page=100'), headers)
    result = JSON.parse response.body
    if !result['success']
      @error_message = "Could not fetch the user profiles related to your app"
    else
      # @profiles = result['result']['profiles'].select do |profile|
      #   0 < profile['applications'].count { |hash| hash['app_id'] == 'com.follow-apps.followme.inHouse' }
      # end
      @profiles = result['result']['profiles']
    end
  end

  def fetch_certificate
    unless @mobile_app
      @error_message = 'Missing parameter'
      return
    end

    response = RestClient.get(url('apps/' + @mobile_app['identifier'] + '/push_certificates'), headers)
    result = JSON.parse response.body
    if !result['success']
      @error_message = "Could not fetch the certificate related to your app"
    else
      @certificate = result['result']['push_certificates'].find { |cert| !cert['revoked'] }
    end
  end

  def revoke_app_cert app_identifier, cert_identifier
    unless app_identifier.present? and cert_identifier.present?
      @error_message = 'Missing parameters'
      return
    end
    response = RestClient.put(url('apps/' + app_identifier + '/push_certificates/' + cert_identifier), {revoked: true}, headers)
    result = JSON.parse response.body
    if !result['success']
      @error_message = "Could not remove the certificate related to your app"
    end
  end

  def create_app_cert app_identifier, cert, pkey
    unless app_identifier.present? && cert.present? && pkey.present?
      @error_message = 'Missing parameters'
      return
    end
    post_params = {
      'x509_pem' => cert,
      'pkey_pem' => pkey
    }
    create_object(url('apps/' + app_identifier + '/push_certificates'), post_params)
  end

  def create_app
    post_params = {
      'name' => 'Heroku demo app',
      'package_name' => mobile_app_package_name,
      'store_id' => mobile_app_package_name,
      'app_type' => 'iOS App',
      'crm_syncable' => true
    }
    create_object(url('apps'), post_params)
  end

  def create_api_key app_identifier
    create_object(url('apps/' + app_identifier + '/api_keys'), {})
  end

   def ensure_transac_campaign(app_identifier)
    get_transac_campaign app_identifier
    return if @campaign.present?

    params = {
      'name' => CAMPAIGN_NAME,
      'type' => 'transactional',
      'source' => 'API',
      'params' => {
        'push_message' => '*@msg@*',
        'template_variables' => [
          {
            'key' => 'msg',
            'value' => 50
          }
        ]
      },
      'app_id' => app_identifier,
      'includes_push' => true,
      'includes_inapp' => false,
      'start_date' => 'now',
      'cmp_action' => 'send'
    }
    @campaign = create_object(url('campaign'), params)
  end

  def get_transac_campaign app_identifier
    response = RestClient.get(url('campaigns?limit=30&offset=0&order=date&status=ongoing&workflow_types=transactional'), headers)
    result = JSON.parse response.body
    if !result['success']
      @error_message = "Could not fetch the campaigns"
    else
      @campaign = result['result'].find { |cmp| cmp['app_id'] == app_identifier && cmp['name'] == CAMPAIGN_NAME }
    end
  end

  def send_transac_push message, user_ids
    return unless @campaign.present? && user_ids.present?

    params = {
      'campaignKey' => [@campaign['api_identifier']],
      'messages' => []
    }
    user_ids.each do |user_id|
      params['messages'] << {
        'templateVars' => { 'msg' => message },
        'user' => user_id
      }
    end
    result = create_object(url('transac_push'), params)
    @info = 'Push sent with requestId ' + result['requestId'].to_s if result['requestId']
  end

  def create_object api_url, params
    begin
      response = RestClient.post(api_url, params.to_json, headers)
    rescue RestClient::ExceptionWithResponse => e
     @error_message = JSON.parse(e.response.body)['error_message']
    end

    if response && (result = JSON.parse response.body) && result['success']
      result['result']
    else
      error_msg = JSON.parse(e.response.body)['error_message']
      @error_message = error_msg
    end
  end

  def headers
    headers = {
      'Content-type' => 'json',
      'Accept' => 'application/json',
      'Authorization' => "Token #{ENV['FOLLOWANALYTICS_API_TOKEN']}"
    }
  end

  def url(endpoint)
    BASE_URL + endpoint
  end

  def mobile_app_package_name
    # to ensure the package_name is unique, we'll use your salesforce login in the app package name
    'com.followanalytics.herokudemo.' + ENV['SALESFORCE_LOGIN'].gsub(/[^0-9A-Za-z\.]/, '')
  end

end
