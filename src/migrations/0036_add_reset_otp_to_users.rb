Sequel.migration do
  change do
    # OTP-based password recovery. The owner/guard requests a reset, receives a
    # short-lived 6-digit code by email, and exchanges a valid code for a
    # one-time reset_token (the existing token columns) to set a new password.
    alter_table(:users) do
      add_column :reset_otp, String, size: 6
      add_column :reset_otp_sent_at, DateTime
      add_column :reset_otp_attempts, Integer, default: 0
    end
  end
end
