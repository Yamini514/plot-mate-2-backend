
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
      r.post('verify-otp') { Users[r].verify_otp }
      r.post('validate-password-token') { Users[r].validate_password_token }
      r.post('reset-password') { Users[r].reset_password }

      # A prospective venture requests a workspace (no auth — they have no
      # account yet). The super admin reviews and approves it. Documents can be
      # attached mid-intake, keyed by the request's human code.
      r.post('onboarding-requests') { Onboarding[r].submit }
      r.post('onboarding-requests', String, 'documents') { |code| Onboarding[r, code: code].attach_document }

      # Admin-issued onboarding invite — the recipient views and accepts it by
      # token (no account yet). Accepting creates their login + an owner
      # verification request for the admin to review. (Roda string matchers are
      # literal — the token segment must be captured with the String class, not
      # a Sinatra-style ':token' placeholder, which never matches.)
      r.get('invites', String)            { |t| Invites[r, token: t].show }
      r.post('invites', String, 'accept') { |t| Invites[r, token: t].accept }

      # Stripe webhook — public but signature-verified (source of truth)
      r.post('stripe/webhook') { StripeBilling[r].webhook }

      r.get('version') { { status: 'success', version: 1 } }

      # TEMP diagnostic — probes outbound TCP reachability to common SMTP ports
      # so we can confirm which ports the host (e.g. Render free tier) blocks.
      # Open /api/smtp-check in a browser; remove this route once debugging is done.
      r.get('smtp-check') do
        require 'socket'
        targets = [
          ['smtp.gmail.com', 587], ['smtp.gmail.com', 465], ['smtp.gmail.com', 25]
        ]
        results = targets.map do |host, port|
          begin
            Socket.tcp(host, port, connect_timeout: 5) { |s| s.close }
            { target: "#{host}:#{port}", reachable: true }
          rescue => e
            { target: "#{host}:#{port}", reachable: false, error: e.message }
          end
        end
        { status: 'success', data: results }
      end

      # Public image proxy — 302s to a short-lived presigned S3 GET so a private
      # bucket's objects load in an <img> tag (which can't send an auth header).
      # Limited to the images/ prefix; keys carry an unguessable UUID.
      r.get('uploads', 'view') { r.redirect(Uploads[r].presigned_view_url) }

      # Authentication required for all routes below
      auth_required!

      # Current-user routes (any authenticated role)
      r.on 'me' do
        r.get('info') { Users[r].info }
        r.get('settings') { Settings[r].show }   # read-only association config (any role)
        r.put('profile') { Users[r].update_self }      # self-edit own contact details
        r.put('update-password') { Users[r].update_password }
        r.post('logout') { Session[r].logout }   # close the session (and any open guard shift)
      end

      # --- Super-admin only (platform layer) --------------------------------
      # Sits above all ventures: review onboarding requests, activate/suspend
      # workspaces. Not tenant-scoped.
      r.on 'super' do
        super_admin_required!

        # 1. Dashboard
        r.get('overview')        { Ventures[r].overview }
        r.get('overview/trends') { Analytics[r].trends }

        # 2. Venture management  (search/filter via query string on the list)
        r.on 'ventures' do
          r.post(Integer, 'suspend')         { |id| Ventures[r, id: id].suspend }
          r.post(Integer, 'activate')        { |id| Ventures[r, id: id].activate }
          r.post(Integer, 'request-changes') { |id| Ventures[r, id: id].request_changes }
          r.post(Integer, 'archive')         { |id| Ventures[r, id: id].archive }
          r.post(Integer, 'support-access')  { |id| Ventures[r, id: id].grant_support_access }
          r.put(Integer, 'info')             { |id| Ventures[r, id: id].update_info }
          r.get(Integer, 'documents')        { |id| Ventures[r, id: id].documents }
          r.get(Integer, 'admins')           { |id| Ventures[r, id: id].admins }
          do_crud(Ventures, r, 'RL')
        end

        # 3. Venture requests (onboarding)
        r.on 'onboarding' do
          r.post(Integer, 'approve')         { |id| Onboarding[r, id: id].approve }
          r.post(Integer, 'reject')          { |id| Onboarding[r, id: id].reject }
          r.post(Integer, 'request-changes') { |id| Onboarding[r, id: id].request_changes }
          r.get(Integer, 'documents')        { |id| Onboarding[r, id: id].documents }
          r.post(Integer, 'documents', Integer, 'verify') { |id, doc| Onboarding[r, id: id, doc: doc].verify_document }
          do_crud(Onboarding, r, 'RL')
        end

        # 4. Venture Admin management
        r.on 'venture-admins' do
          r.post(Integer, 'activate')       { |id| VentureAdmins[r, id: id].activate }
          r.post(Integer, 'deactivate')     { |id| VentureAdmins[r, id: id].deactivate }
          r.post(Integer, 'reset-password') { |id| VentureAdmins[r, id: id].reset_password }
          do_crud(VentureAdmins, r, 'RL')
        end

        # 5. User management (all users, all ventures)
        r.on 'users' do
          r.post(Integer, 'block')          { |id| PlatformUsers[r, id: id].block }
          r.post(Integer, 'unblock')        { |id| PlatformUsers[r, id: id].unblock }
          r.post(Integer, 'reset-password') { |id| PlatformUsers[r, id: id].reset_password }
          do_crud(PlatformUsers, r, 'RL')
        end

        # 6. Support & tickets
        r.on 'tickets' do
          r.post(Integer, 'assign')   { |id| PlatformTickets[r, id: id].assign }
          r.post(Integer, 'status')   { |id| PlatformTickets[r, id: id].update_status }
          r.post(Integer, 'reply')    { |id| PlatformTickets[r, id: id].reply }
          r.post(Integer, 'escalate') { |id| PlatformTickets[r, id: id].escalate }
          do_crud(PlatformTickets, r, 'CRL')
        end

        # 7. Audit logs (read-only)
        r.on('audit-logs') { do_crud(AuditLogs, r, 'L') }

        # 8. Global settings
        r.on 'settings' do
          r.get                { PlatformSettings[r].show }
          r.put                { PlatformSettings[r].update }
          r.post('test-email') { PlatformSettings[r].test_email }
        end

        # 9. Reports & analytics
        r.on 'reports' do
          r.get('venture-growth') { Analytics[r].venture_growth }
          r.get('user-growth')    { Analytics[r].user_growth }
          r.get('registrations')  { Analytics[r].registration_trends }
          r.get('active-ventures'){ Analytics[r].active_ventures }
          r.get('revenue')        { Analytics[r].revenue }
          r.get('export')         { Analytics[r].export }
        end

        # 10. Global Notification Center (platform announcements)
        r.on 'announcements' do
          r.post(Integer, 'publish') { |id| PlatformAnnouncements[r, id: id].publish }
          do_crud(PlatformAnnouncements, r, 'CRUDL')
        end

        # 11. Feature management (per-venture toggles)
        r.on 'features' do
          r.post(Integer, 'toggle') { |id| PlatformFeatures[r, id: id].toggle }
          r.get { PlatformFeatures[r].index }
        end

        # 12. System health
        r.on('health') { SystemHealth[r].overview }
      end

      # --- Admin-only -------------------------------------------------------
      r.on 'admin' do
        admin_required!
        r.on 'users' do
          r.post(Integer, 'deactivate') { |id| Users[r, id: id].deactivate }
          r.post(Integer, 'activate')   { |id| Users[r, id: id].activate }
          do_crud(Users, r, 'CRUDL')
        end
        r.on('uploads') { r.post('presign') { Uploads[r].presign } } # presigned S3 URL (or inline fallback)

        # Onboarding invites (members/owners) — admin issues, recipient accepts.
        r.on 'invites' do
          r.post(Integer, 'resend') { |id| Invites[r, id: id].resend }
          r.post(Integer, 'revoke') { |id| Invites[r, id: id].revoke }
          do_crud(Invites, r, 'CL')
        end

        # Approval queue (the request engine) — owner verification, plot claims,
        # ownership transfers, document verification.
        r.on 'approvals' do
          r.post(Integer, 'approve')         { |id| Approvals[r, id: id].approve }
          r.post(Integer, 'reject')          { |id| Approvals[r, id: id].reject }
          r.post(Integer, 'request-changes') { |id| Approvals[r, id: id].request_changes }
          r.post(Integer, 'comment')         { |id| Approvals[r, id: id].comment }
          do_crud(Approvals, r, 'CRL')
        end

        # Ownership transfers — initiate, attach deed/NOC, cancel. The decision
        # itself happens in the Approvals queue.
        r.on 'transfers' do
          r.post('initiate')                { Transfers[r].initiate }
          r.post(Integer, 'documents')      { |id| Transfers[r, id: id].attach_document }
          r.post(Integer, 'cancel')         { |id| Transfers[r, id: id].cancel }
          do_crud(Transfers, r, 'RL')
        end
        r.on 'plots' do
          r.get('summary') { Plots[r].summary }
          r.post('import')  { Plots[r].import_rows }   # bulk upload (Excel/CSV) → upsert by plot_no
          r.post('generate') { Plots[r].generate_plots } # create empty plots from number ranges read off the map
          r.post('apply-base-pay') { Plots[r].apply_base_pay } # bulk (re)generate dues
          r.post(Integer, 'register-owner') { |id| Plots[r, id: id].register_owner } # assign owner to an existing plot
          r.post(Integer, 'approve')        { |id| Plots[r, id: id].approve }        # verify a registered owner
          r.post('merge')                   { Plots[r].merge_plots }
          r.post(Integer, 'reserve')        { |id| Plots[r, id: id].reserve }
          r.post(Integer, 'unreserve')      { |id| Plots[r, id: id].unreserve }
          r.post(Integer, 'split')          { |id| Plots[r, id: id].split_plot }
          # Multiple (joint) owners per plot.
          r.on(Integer, 'owners') do |pid|
            r.post(Integer, 'primary') { |oid| Plots[r, id: pid, owner: oid].set_primary }
            r.delete(Integer)          { |oid| Plots[r, id: pid, owner: oid].remove_owner }
            r.post                     { Plots[r, id: pid].add_owner }
            r.get                      { Plots[r, id: pid].owners }
          end
          do_crud(Plots, r, 'CRUDL')
        end

        # Interactive site plan: imported layout image + per-plot clickable regions.
        r.on 'plot-map' do
          r.put('layout')    { PlotMap[r].save_layout }
          r.delete('layout') { PlotMap[r].remove_layout }
          r.put('regions')   { PlotMap[r].save_regions }
          r.post('detect')   { PlotMap[r].detect_plots }   # AI vision: read plot numbers off the image
          r.get              { PlotMap[r].show }
        end

        r.on 'billing' do
          r.on('plans') { do_crud(Plans, r, 'CRUDL') }

          r.on 'invoices' do
            r.get('summary')             { Invoices[r].summary }
            r.get('defaulters')          { Invoices[r].defaulters }
            r.get('demand-statement')    { Invoices[r].demand_statement } # ?plot_id=
            r.get('fund-summary')        { Invoices[r].fund_summary }     # collected by category (corpus etc.)
            r.get('export')              { Invoices[r].export_csv }
            r.post('generate')           { Invoices[r].generate }
            r.post('charge')             { Invoices[r].charge }           # one-off, single owner
            r.post('status')             { Invoices[r].set_status }       # bulk transition
            r.post('apply-late-fees')    { Invoices[r].apply_late_fees }
            r.post('apply-interest')     { Invoices[r].apply_interest }  # monthly interest on overdue
            r.post(Integer, 'adjust') { |id| Invoices[r, id: id].adjust } # waiver/discount
            do_crud(Invoices, r, 'CRUL')                                  # no hard delete
          end

          r.on 'payments' do
            r.get(Integer, 'receipt')   { |id| Payments[r, id: id].receipt }
            r.post(Integer, 'verify')   { |id| Payments[r, id: id].verify }
            r.post(Integer, 'reject')   { |id| Payments[r, id: id].reject }
            r.post(Integer, 'reconcile'){ |id| Payments[r, id: id].reconcile }
            do_crud(Payments, r, 'CRL')                                   # immutable records
          end

          # Refunds / credit reversals against a payment.
          r.on 'refunds' do
            r.post(Integer, 'approve')   { |id| Refunds[r, id: id].approve }
            r.post(Integer, 'reject')    { |id| Refunds[r, id: id].reject }
            r.post(Integer, 'mark-paid') { |id| Refunds[r, id: id].mark_paid }
            do_crud(Refunds, r, 'CRL')
          end

          r.on('transactions') { do_crud(Transactions, r, 'L') }         # treasury ledger
        end

        r.on 'complaints' do
          r.get('summary')              { Complaints[r].summary }
          r.post(Integer, 'assign')   { |id| Complaints[r, id: id].assign }
          r.post(Integer, 'resolve')  { |id| Complaints[r, id: id].resolve }
          r.post(Integer, 'escalate') { |id| Complaints[r, id: id].escalate }
          r.post(Integer, 'reopen')   { |id| Complaints[r, id: id].reopen }
          r.post(Integer, 'note')     { |id| Complaints[r, id: id].add_note }
          r.post(Integer, 'attachments') { |id| Complaints[r, id: id].attach }
          do_crud(Complaints, r, 'CRUDL')
        end

        r.on 'helpdesk' do
          r.on 'tickets' do
            r.get('summary')            { Tickets[r].summary }
            r.get('export')             { Tickets[r].export_csv }
            r.post(Integer, 'transition') { |id| Tickets[r, id: id].transition }
            r.post(Integer, 'assign')     { |id| Tickets[r, id: id].assign }
            r.post(Integer, 'accept')     { |id| Tickets[r, id: id].accept }
            r.post(Integer, 'reject')     { |id| Tickets[r, id: id].reject }
            r.post(Integer, 'photos')     { |id| Tickets[r, id: id].attach_photo }
            r.post(Integer, 'complete')   { |id| Tickets[r, id: id].complete }
            r.post(Integer, 'escalate')   { |id| Tickets[r, id: id].escalate }
            r.post(Integer, 'materials')  { |id| Tickets[r, id: id].add_material }
            r.delete(Integer, 'materials', Integer) { |id, mid| Tickets[r, id: id, material: mid].remove_material }
            do_crud(Tickets, r, 'CRUDL')
          end
        end

        # --- Community ---
        r.on 'announcements' do
          r.post(Integer, 'pin')     { |id| Announcements[r, id: id].pin }
          r.post(Integer, 'ack')     { |id| Announcements[r, id: id].ack }
          r.post(Integer, 'comment') { |id| Announcements[r, id: id].comment }
          r.post(Integer, 'react')   { |id| Announcements[r, id: id].react }
          r.post(Integer, 'comments', Integer, 'moderate') { |id, cid| Announcements[r, id: id, comment: cid].moderate_comment }
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
          r.get('guard-sessions') { Security[r].guard_sessions }
          r.on 'incidents' do
            r.post(Integer, 'status') { |id| Incidents[r, id: id].set_status }
            do_crud(Incidents, r, 'CRUDL')
          end
          r.on('blacklist') { do_crud(Blacklist, r, 'CRUDL') }
        end

        # --- Content ---
        r.on 'documents' do
          r.get('expiring')          { Documents[r].expiring }   # ?days=30
          r.post('presign')          { Documents[r].presign }
          r.on('folders')            { do_crud(DocumentFolders, r, 'CLD') }
          r.post(Integer, 'approve') { |id| Documents[r, id: id].approve }
          r.post(Integer, 'versions') { |id| Documents[r, id: id].new_version }
          r.get(Integer, 'versions')  { |id| Documents[r, id: id].versions }
          do_crud(Documents, r, 'CRUDL')
        end
        r.on('photos') { do_crud(Photos, r, 'CRUDL') }

        # --- Org / finance / admin ---
        r.on 'staff' do
          r.get('eligible')          { Staff[r].eligible }   # verified vendors for assignment
          r.get(Integer, 'performance') { |id| Staff[r, id: id].performance }
          r.post(Integer, 'verify')  { |id| Staff[r, id: id].verify }
          r.post(Integer, 'rate')      { |id| Staff[r, id: id].rate }
          r.post(Integer, 'preferred') { |id| Staff[r, id: id].toggle_preferred }
          r.post(Integer, 'create-login') { |id| Staff[r, id: id].create_login } # vendor portal login
          do_crud(Staff, r, 'CRUDL')
        end

        # Preventive / recurring maintenance schedules + completion logs.
        r.on 'maintenance' do
          r.post(Integer, 'log')    { |id| Maintenance[r, id: id].log_completion }
          r.post(Integer, 'toggle') { |id| Maintenance[r, id: id].toggle_active }
          do_crud(Maintenance, r, 'CRUDL')
        end

        # Capital / improvement projects: budget, milestones, progress, delays.
        r.on 'projects' do
          r.post(Integer, 'update')   { |id| Projects[r, id: id].add_update }
          r.post(Integer, 'photos')   { |id| Projects[r, id: id].attach_photo }
          r.post(Integer, 'complete') { |id| Projects[r, id: id].complete }
          r.post(Integer, 'milestones')         { |id| Projects[r, id: id].add_milestone }
          r.post(Integer, 'milestones', Integer, 'toggle') { |id, mid| Projects[r, id: id, milestone: mid].toggle_milestone }
          r.delete(Integer, 'milestones', Integer)         { |id, mid| Projects[r, id: id, milestone: mid].delete_milestone }
          r.post(Integer, 'comment')  { |id| Projects[r, id: id].comment }
          r.post(Integer, 'react')    { |id| Projects[r, id: id].react }
          r.post(Integer, 'comments', Integer, 'moderate') { |id, cid| Projects[r, id: id, comment: cid].moderate_comment }
          do_crud(Projects, r, 'CRUDL')
        end
        r.on 'reminders' do
          r.post('generate')      { Reminders[r].generate }   # auto-schedule for all defaulters
          r.post(Integer, 'send') { |id| Reminders[r, id: id].send_now }
          do_crud(Reminders, r, 'CRUDL')
        end
        r.on 'treasury' do
          r.on 'expenses' do
            r.get('by-category') { Expenses[r].by_category }
            do_crud(Expenses, r, 'CRUDL')
          end
          r.on 'transactions' do
            r.post('funds') { Transactions[r].add_funds }
            r.delete(Integer) { |id| Transactions[r, id: id].delete }
            do_crud(Transactions, r, 'L')
          end
        end
        r.on 'settings' do
          r.post('test-email') { Settings[r].test_email }
          r.get { Settings[r].show }
          r.put { Settings[r].update }
        end
        r.on('reports') { r.get('overview') { Reports[r].overview } }
        r.on('directory') { Directory[r].list }

        # Custom committee roles + permissions (the approval matrix references
        # these by name; matrix itself is saved via /admin/settings).
        r.on('roles') { do_crud(Roles, r, 'CRUDL') }
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
        r.get('verify-plot')    { GuardReports[r].verify_plot }
        r.get('shift-roster')   { GuardReports[r].shift_roster }
        r.get('recent-actions') { GuardReports[r].recent_actions }
      end

      # --- Vendor-only (service-partner portal) -----------------------------
      # A vendor logs in to work the orders assigned to their staff record. The
      # Tickets service enforces that they can only touch their own assignments.
      r.on 'vendor' do
        vendor_required!
        r.on 'tickets' do
          r.get(Integer)                { |id| Tickets[r, id: id].get }
          r.post(Integer, 'accept')     { |id| Tickets[r, id: id].accept }
          r.post(Integer, 'reject')     { |id| Tickets[r, id: id].reject }
          r.post(Integer, 'transition') { |id| Tickets[r, id: id].transition }
          r.post(Integer, 'photos')     { |id| Tickets[r, id: id].attach_photo }
          r.post(Integer, 'complete')   { |id| Tickets[r, id: id].complete }
          r.get { Tickets[r, assigned_to_me: 'true'].list }
        end
      end

      # --- Member-only ------------------------------------------------------
      r.on 'member' do
        member_required!
        r.on 'notifications' do
          r.get('unread')         { Notifications[r].unread }
          r.post('read-all')      { Notifications[r].mark_all_read }
          r.post(Integer, 'read') { |id| Notifications[r, id: id].mark_read }
          r.get                   { Notifications[r].list }
        end
        # Owner self-service: track own approval requests (claim/transfer/etc.).
        r.on 'requests' do
          r.post(Integer, 'documents') { |id| Approvals[r, id: id].member_attach_document }
          r.post(Integer, 'resubmit')  { |id| Approvals[r, id: id].member_resubmit }
          r.get(Integer)               { |id| Approvals[r, id: id].member_get }
          r.get                        { Approvals[r].member_list }
        end
        # Owner-initiated ownership transfer of their own plot.
        r.on 'transfers' do
          r.post('initiate')           { Transfers[r].member_initiate }
          r.post(Integer, 'documents') { |id| Transfers[r, id: id].member_attach_document }
          r.get                        { Transfers[r].member_list }
        end
        r.on 'billing' do
          r.get { MemberBilling[r].overview }
          r.post('pay')           { MemberBilling[r].pay }
          r.post('stripe-intent') { StripeBilling[r].create_intent }
        end
        r.on 'plots' do
          r.get('search') { MemberBilling[r].plot_search }   # find a plot to claim
          r.post('claim') { MemberBilling[r].claim_plot }    # submit proof → plot_claim approval
          r.get(Integer, 'history') { |id| MemberBilling[r, id: id].plot_history }
          r.get { MemberBilling[r].my_plots }
        end
        r.on('payments') { MemberBilling[r].my_payments }
        r.on('treasury') { MemberBilling[r].treasury }
        r.on 'visitors' do
          r.post(Integer, 'approve') { |id| MemberBilling[r, id: id].approve_visitor }
          r.post(Integer, 'reject')  { |id| MemberBilling[r, id: id].reject_visitor }
          r.post { MemberBilling[r].preapprove_visitor }
          r.get  { MemberBilling[r].my_visitors }
        end

        r.on 'complaints' do
          r.post(Integer, 'confirm') { |id| Complaints[r, id: id].confirm_resolution }
          r.post(Integer, 'reopen')  { |id| Complaints[r, id: id].reopen }
          r.get(Integer)             { |id| Complaints[r, id: id].get }
          r.get  { Complaints[r, mine: 'true'].list }
          r.post { Complaints[r].create }
        end

        r.on 'helpdesk' do
          r.get  { Tickets[r, mine: 'true'].list }
          r.post { Tickets[r].create }
          r.post(Integer, 'verify') { |id| Tickets[r, id: id].verify }
        end

        # --- Community (member) ---
        r.on 'announcements' do
          r.get(Integer)            { |id| Announcements[r, id: id].get }
          r.post(Integer, 'ack')     { |id| Announcements[r, id: id].ack }
          r.post(Integer, 'comment') { |id| Announcements[r, id: id].comment }
          r.post(Integer, 'react')   { |id| Announcements[r, id: id].react }
          r.get { Announcements[r].list }
        end
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

        # --- Content + directory (member) ---
        r.on 'documents' do
          r.post(Integer, 'versions') { |id| Documents[r, id: id].member_new_version } # replace own doc
          r.post { Documents[r].member_create }   # owner uploads (pending admin approval)
          r.get  { Documents[r].list }
        end
        r.on('photos')    { Photos[r].list }
        r.on('directory') { Directory[r].list }

        # Capital projects — read-only view + discussion (comment / react).
        r.on 'projects' do
          r.get(Integer)             { |id| Projects[r, id: id].member_get }
          r.post(Integer, 'comment') { |id| Projects[r, id: id].comment }
          r.post(Integer, 'react')   { |id| Projects[r, id: id].react }
          r.get { Projects[r].member_list }
        end
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

  def super_admin_required!
    forbidden! unless App.cu.user_obj&.super_admin?
  end

  def guard_required!
    forbidden! unless App.cu.user_obj&.guard? || App.cu.user_obj&.admin?
  end

  def member_required!
    forbidden! unless App.cu.user_obj&.member? || App.cu.user_obj&.admin?
  end

  def vendor_required!
    forbidden! unless App.cu.user_obj&.vendor? || App.cu.user_obj&.admin?
  end
end

App.require_blob('services/base.rb')
App.require_blob('services/*.rb')

App::Routes.send(:include, App::Services)