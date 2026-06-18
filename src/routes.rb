
class App::Routes < Roda
  include App::Router::AllPlugins
  plugin :not_found do
    { status: 'error', data: 'Not Found' }
  end

  def do_crud(klass, r, only='CRUDL', opts = {})
    r.post { klass[r, opts].create } if only.include?('C')
    r.get(Integer) {|id| klass[r, opts.merge(id: id)].get} if only.include?('R')
    r.get { klass[r, opts].list } if only.include?('L')
    r.put(Integer) {|id| klass[r, opts.merge(id: id)].update } if only.include?('U')
    r.delete(Integer) {|id| klass[r, opts.merge(id: id)].delete } if only.include?('D')
  end

  route do |r|
    r.public

    r.root do
      { status: 'success', service: 'PlotMate API' }
    end

    r.on 'api' do
      r.response['Content-Type'] = 'application/json'

      # Public endpoints (no auth required)
      r.post('login') { Session[r].login }
      r.post('forgot-password') { Users[r].forgot_password }
      r.post('validate-password-token') { Users[r].validate_password_token }
      r.post('reset-password') { Users[r].reset_password }

      # Stripe webhook — public but signature-verified (source of truth)
      r.post('stripe/webhook') { StripeBilling[r].webhook }

      r.get('version') { { status: 'success', version: 1 } }

      # Authentication required for all routes below
      auth_required!

      # Current-user routes (any authenticated role)
      r.on 'me' do
        r.get('info') { Users[r].info }
        r.get('settings') { Settings[r].show }   # read-only association config (any role)
        r.put('profile') { Users[r].update_self }      # self-edit own contact details
        r.put('update-password') { Users[r].update_password }
      end

      # --- Admin-only -------------------------------------------------------
      r.on 'admin' do
        admin_required!
        r.on('users') { do_crud(Users, r, 'CRUDL') }
        r.on 'plots' do
          r.get('summary') { Plots[r].summary }
          r.post('import')  { Plots[r].import_rows }   # bulk upload (Excel/CSV) → upsert by plot_no
          do_crud(Plots, r, 'CRUDL')
        end

        # Interactive site plan: imported layout image + per-plot clickable regions.
        r.on 'plot-map' do
          r.put('layout')    { PlotMap[r].save_layout }
          r.delete('layout') { PlotMap[r].remove_layout }
          r.put('regions')   { PlotMap[r].save_regions }
          r.get              { PlotMap[r].show }
        end

        r.on 'billing' do
          r.on('plans') { do_crud(Plans, r, 'CRUDL') }

          r.on 'invoices' do
            r.get('summary')             { Invoices[r].summary }
            r.get('defaulters')          { Invoices[r].defaulters }
            r.get('export')              { Invoices[r].export_csv }
            r.post('generate')           { Invoices[r].generate }
            r.post('status')             { Invoices[r].set_status }       # bulk transition
            r.post('apply-late-fees')    { Invoices[r].apply_late_fees }
            r.post(Integer, 'adjust') { |id| Invoices[r, id: id].adjust } # waiver/discount
            do_crud(Invoices, r, 'CRUL')                                  # no hard delete
          end

          r.on 'payments' do
            r.get(Integer, 'receipt') { |id| Payments[r, id: id].receipt }
            do_crud(Payments, r, 'CRL')                                   # immutable records
          end

          r.on('transactions') { do_crud(Transactions, r, 'L') }         # treasury ledger
        end

        r.on 'complaints' do
          r.get('summary')              { Complaints[r].summary }
          r.post(Integer, 'assign')  { |id| Complaints[r, id: id].assign }
          r.post(Integer, 'resolve') { |id| Complaints[r, id: id].resolve }
          do_crud(Complaints, r, 'CRUDL')
        end

        r.on 'helpdesk' do
          r.on 'tickets' do
            r.get('summary')            { Tickets[r].summary }
            r.get('export')             { Tickets[r].export_csv }
            r.post(Integer, 'transition') { |id| Tickets[r, id: id].transition }
            r.post(Integer, 'assign')     { |id| Tickets[r, id: id].assign }
            r.post(Integer, 'escalate')   { |id| Tickets[r, id: id].escalate }
            do_crud(Tickets, r, 'CRUDL')
          end
        end

        # --- Community ---
        r.on 'announcements' do
          r.post(Integer, 'pin') { |id| Announcements[r, id: id].pin }
          do_crud(Announcements, r, 'CRUDL')
        end
        r.on 'events' do
          r.post(Integer, 'rsvp') { |id| Events[r, id: id].rsvp }
          do_crud(Events, r, 'CRUDL')
        end
        r.on 'polls' do
          r.post(Integer, 'close') { |id| Polls[r, id: id].close }
          r.post(Integer, 'vote')  { |id| Polls[r, id: id].vote }
          do_crud(Polls, r, 'CRUDL')
        end
        r.on('amenities') { do_crud(Amenities, r, 'CRUDL') }
        r.on 'bookings' do
          r.post(Integer, 'status') { |id| Bookings[r, id: id].set_status }
          do_crud(Bookings, r, 'CRUDL')
        end

        # --- Gate (admin view) ---
        r.on 'visitors' do
          r.post(Integer, 'action') { |id| Visitors[r, id: id].action }
          do_crud(Visitors, r, 'CRUDL')
        end
        r.on('deliveries') { do_crud(Deliveries, r, 'CRUDL') }
        r.on 'security' do
          r.get('overview') { Security[r].overview }
          r.on 'incidents' do
            r.post(Integer, 'status') { |id| Incidents[r, id: id].set_status }
            do_crud(Incidents, r, 'CRUDL')
          end
          r.on('blacklist') { do_crud(Blacklist, r, 'CRUDL') }
        end

        # --- Content ---
        r.on 'documents' do
          r.post('presign') { Documents[r].presign }
          r.post(Integer, 'approve') { |id| Documents[r, id: id].approve }
          do_crud(Documents, r, 'CRUDL')
        end
        r.on('photos') { do_crud(Photos, r, 'CRUDL') }

        # --- Org / finance / admin ---
        r.on('staff') { do_crud(Staff, r, 'CRUDL') }
        r.on 'reminders' do
          r.post(Integer, 'send') { |id| Reminders[r, id: id].send_now }
          do_crud(Reminders, r, 'CRUDL')
        end
        r.on 'treasury' do
          r.on 'expenses' do
            r.get('by-category') { Expenses[r].by_category }
            do_crud(Expenses, r, 'CRUDL')
          end
          r.on('transactions') { do_crud(Transactions, r, 'L') }
        end
        r.on 'settings' do
          r.get { Settings[r].show }
          r.put { Settings[r].update }
        end
        r.on('reports') { r.get('overview') { Reports[r].overview } }
        r.on('directory') { Directory[r].list }
        # future admin resources go here
      end

      # --- Guard-only -------------------------------------------------------
      r.on 'guard' do
        guard_required!
        r.on 'tickets' do
          r.get  { Tickets[r, mine: 'true'].list }
          r.post { Tickets[r].create }
        end
        r.on 'visitors' do
          r.post(Integer, 'action') { |id| Visitors[r, id: id].action }
          do_crud(Visitors, r, 'CRL')
        end
        r.on 'deliveries' do
          r.post(Integer, 'handover') { |id| Deliveries[r, id: id].handover }
          do_crud(Deliveries, r, 'CRL')
        end
        r.on 'incidents' do
          r.post(Integer, 'status') { |id| Incidents[r, id: id].set_status }
          do_crud(Incidents, r, 'CRL')
        end
        r.on('blacklist') { do_crud(Blacklist, r, 'CRL') }
        r.on('reports')   { GuardReports[r].summary }
        r.on('residents') { GuardReports[r].residents }
        r.get('shift-roster')   { GuardReports[r].shift_roster }
        r.get('recent-actions') { GuardReports[r].recent_actions }
      end

      # --- Member-only ------------------------------------------------------
      r.on 'member' do
        member_required!
        r.on 'billing' do
          r.get { MemberBilling[r].overview }
          r.post('pay')           { MemberBilling[r].pay }
          r.post('stripe-intent') { StripeBilling[r].create_intent }
        end
        r.on('plots')    { MemberBilling[r].my_plots }
        r.on('payments') { MemberBilling[r].my_payments }
        r.on('treasury') { MemberBilling[r].treasury }
        r.on 'visitors' do
          r.post(Integer, 'approve') { |id| MemberBilling[r, id: id].approve_visitor }
          r.post(Integer, 'reject')  { |id| MemberBilling[r, id: id].reject_visitor }
          r.post { MemberBilling[r].preapprove_visitor }
          r.get  { MemberBilling[r].my_visitors }
        end

        r.on 'complaints' do
          r.get  { Complaints[r, mine: 'true'].list }
          r.post { Complaints[r].create }
        end

        r.on 'helpdesk' do
          r.get  { Tickets[r, mine: 'true'].list }
          r.post { Tickets[r].create }
          r.post(Integer, 'verify') { |id| Tickets[r, id: id].verify }
        end

        # --- Community (member) ---
        r.on('announcements') { Announcements[r].list }
        r.on 'events' do
          r.post(Integer, 'rsvp') { |id| Events[r, id: id].rsvp }
          r.get { Events[r].list }
        end
        r.on 'polls' do
          r.post(Integer, 'vote') { |id| Polls[r, id: id].vote }
          r.get { Polls[r].list }
        end
        r.on('amenities') { Amenities[r].list }
        r.on 'bookings' do
          r.get  { Bookings[r, mine: 'true'].list }
          r.post { Bookings[r].create }
          r.post(Integer, 'cancel') { |id| Bookings[r, id: id, status: 'cancelled'].set_status }
        end

        # --- Content + directory (member, read-only) ---
        r.on('documents') { Documents[r].list }
        r.on('photos')    { Photos[r].list }
        r.on('directory') { Directory[r].list }
      end
    end
  end

  before do
    @time = Time.now
    App::Helpers::Before.run!(request)
  end

  after do |res|
    rtype = request.request_method
    App.logger.info("→ [#{Time.now - @time} seconds] - [#{rtype}]#{request.path}")
  end

  def auth_required!
    unless App.cu.valid?
      request.halt(401, {'Content-Type' => 'application/json'},{ status: 'Unauthorized!' }.to_json)
    end
  end

  def forbidden!
    request.halt(403, {'Content-Type' => 'application/json'}, { status: 'Forbidden!' }.to_json)
  end

  def admin_required!
    forbidden! unless App.cu.user_obj&.admin?
  end

  def guard_required!
    forbidden! unless App.cu.user_obj&.guard? || App.cu.user_obj&.admin?
  end

  def member_required!
    forbidden! unless App.cu.user_obj&.member? || App.cu.user_obj&.admin?
  end
end

App.require_blob('services/base.rb')
App.require_blob('services/*.rb')

App::Routes.send(:include, App::Services)