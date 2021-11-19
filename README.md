# Devourer

貪る者

## Disclaimer

おれ専用ツールです

## Requirements

- Docker
- Docker Compose

## Usage

- build

```
cp settings.yml.sample settings.yml
docker-compose build
docker-compose run --rm app carton install --deployment
```

- settings.yml
    - twitter: Put secrets.
    - outdir: Picture file output destination.
    - mediators: Specify target displayname of user as array.
    - lists: Specify target list id.
    - min_followers: Set the minimum number of followers for tweets to be notified.
        - Only the users in the list are targeted, not the mediators.
    - discord_webhook_url: Notify discord of tweets with media from users who have not been added to the list and have never been notified.

- how to run (recommended)

```
# in crontab

*/5 * * * * cd /path/to/devourer && flock -nx /tmp/devourer_twitter_fetch.lock $CMD twitter fetch

## (Optional) Automatically muting users you have added to your list makes it easier to meet new users when browsing your timeline.
## But it is anti-social.
*/5 * * * * cd /path/to/devourer && flock -nx /tmp/devourer_twitter_automute.lock $CMD twitter automute
```

### How to maintenance Redis

- だりーからソースよめ
