class App::Services::StripeBilling < App::Services::Base
  # Create a PaymentIntent for an invoice; returns a client_secret the frontend
  # confirms with Stripe.js. (Requires STRIPE_SECRET_KEY.)
  def create_intent
    return_errors!('Stripe is not configured', 503) if ENV['STRIPE_SECRET_KEY'].blank?
    Stripe.api_key = ENV['STRIPE_SECRET_KEY']

    inv = Invoice[client_id: current_client_id, id: params[:invoice_id]] ||
          return_errors!('Invoice not found', 404)
    amount_paise = inv.balance_paise.to_i
    return_errors!('Nothing due', 400) if amount_paise <= 0

    intent = Stripe::PaymentIntent.create(
      amount: amount_paise, currency: 'inr',
      metadata: { invoice_id: inv.id, client_id: inv.client_id, number: inv.number }
    )
    return_success(client_secret: intent.client_secret,
                   payment_intent: intent.id, amount: amount_paise / 100)
  rescue => e
    App.logger.error("Stripe intent error: #{e.message}")
    return_errors!("Payment init failed: #{e.message}", 502)
  end

  # Webhook — the source of truth for Stripe payments. Verifies the signature,
  # then idempotently records the payment (which also posts to treasury).
  def webhook
    payload = r.body.read
    secret  = ENV['STRIPE_WEBHOOK_SECRET']

    event =
      if secret.present?
        Stripe::Webhook.construct_event(payload, r.env['HTTP_STRIPE_SIGNATURE'], secret)
                       .to_hash
      else
        JSON.parse(payload, symbolize_names: true)
      end

    if event[:type] == 'payment_intent.succeeded'
      pi     = event.dig(:data, :object) || {}
      pi_id  = pi[:id]
      inv_id = pi.dig(:metadata, :invoice_id)
      inv    = Invoice[inv_id.to_i] if inv_id

      already = pi_id && Payment.where(provider_ref: pi_id).count.positive?
      if inv && !already
        Payment.record!(invoice: inv, amount_paise: pi[:amount], mode: 'card',
                        provider: 'stripe', provider_ref: pi_id, reference: pi_id)
      end
    end

    { status: 'success', received: true }
  rescue => e
    App.logger.error("Stripe webhook error: #{e.message}")
    r.halt(400, { 'Content-Type' => 'application/json' },
           { status: 'error', message: e.message }.to_json)
  end
end
