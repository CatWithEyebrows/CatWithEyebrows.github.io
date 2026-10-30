#!/bin/sh
# Preview the site, drafts and scheduled posts included, at http://localhost:4000
exec docker run --rm --name blog-preview -v "$PWD":/srv/jekyll -v blog-gems:/usr/local/bundle -w /srv/jekyll -p 4000:4000 ruby:3.3 \
  sh -c "bundle install --quiet && bundle exec jekyll serve --drafts --future --host 0.0.0.0 --livereload"
