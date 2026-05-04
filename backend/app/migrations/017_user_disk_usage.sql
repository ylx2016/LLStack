-- Cache table for per-user home directory disk usage. Refreshed by an
-- hourly cron job (scripts/system/user-disk-refresh.sh); the user list
-- API reads from this cache instead of fork+du-ing on every request,
-- which previously could hang gunicorn for minutes on installs with many
-- large home dirs.
CREATE TABLE IF NOT EXISTS user_disk_usage (
    user_id INTEGER PRIMARY KEY,
    mb INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
