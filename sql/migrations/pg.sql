-- 1 up
CREATE TABLE IF NOT EXISTS saved_media_files (
    id  BIGSERIAL NOT NULL PRIMARY KEY,
    service_name TEXT NOT NULL,
    filename TEXT NOT NULL,
    filepath TEXT NOT NULL
);
CREATE INDEX ON saved_media_files (filepath);

CREATE TABLE IF NOT EXISTS twitter_already_read_users (
    id              BIGSERIAL NOT NULL PRIMARY KEY,
    twitter_user_id TEXT NOT NULL
);
CREATE INDEX ON twitter_already_read_users (twitter_user_id);

CREATE TABLE IF NOT EXISTS twitter_already_read_list_members (
    id              BIGSERIAL NOT NULL PRIMARY KEY,
    twitter_user_id TEXT NOT NULL
);
CREATE INDEX ON twitter_already_read_list_members (twitter_user_id);

-- 1 down
DROP TABLE saved_media_files;
DROP TABLE twitter_already_read_users;
DROP TABLE twitter_already_read_list_members;
