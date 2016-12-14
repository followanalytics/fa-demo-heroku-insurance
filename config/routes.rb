Rails.application.routes.draw do
  get 'push/index'
  post 'push/index' => 'push#create'
  get 'push/reset_certificate' => 'push#destroy_certificate'
  post 'push/certificate' => 'push#create_certificate'
  post 'push/send' => 'push#send_push'

  root 'push#index'
end
