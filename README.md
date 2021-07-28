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
    - twitter: put secrets
    - outdir: picture file output destination (default: media)
    - mediators: specify target displayname of user as array
    - lists: specify target list id
    - slack_webhook_url: notify slack of tweets with media from users who have not been added to the list and have never been notified.

- run

```
docker-compose up -d redis
docker-compose up -d app
```
