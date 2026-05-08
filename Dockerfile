# cache-bust: 2026-05-07
FROM ruby:3.4.7-alpine AS ig_download

WORKDIR /fonts

RUN apk --no-cache add wget && \
    wget https://github.com/satbyy/go-noto-universal/releases/download/v7.0/GoNotoKurrent-Regular.ttf && \
    wget https://github.com/satbyy/go-noto-universal/releases/download/v7.0/GoNotoKurrent-Bold.ttf && \
    wget https://github.com/impallari/DancingScript/raw/master/fonts/DancingScript-Regular.otf && \
    wget https://raw.githubusercontent.com/impallari/DancingScript/master/OFL.txt && \
    wget https://raw.githubusercontent.com/notofonts/noto-fonts/refs/heads/main/LICENSE && \
    wget -O /model.onnx "https://github.com/docusealco/fields-detection/releases/download/2.0.0/model_704_int8.onnx" && \
    wget -O pdfium-linux.tgz "https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-linux-musl-$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/').tgz" && \
    mkdir -p /pdfium-linux && \
    tar -xzf pdfium-linux.tgz -C /pdfium-linux

FROM ruby:3.4.7-alpine AS ig_webpack

ENV RAILS_ENV=production
ENV NODE_ENV=production

WORKDIR /app

RUN apk add --no-cache nodejs yarn git build-base && \
    gem install shakapacker

COPY ./package.json ./yarn.lock ./

RUN yarn install --network-timeout 1000000

COPY ./bin/shakapacker ./bin/shakapacker
COPY ./config/webpack ./config/webpack
COPY ./config/shakapacker.yml ./config/shakapacker.yml
COPY ./postcss.config.js ./postcss.config.js
COPY ./tailwind.config.js ./tailwind.config.js
COPY ./tailwind.form.config.js ./tailwind.form.config.js
COPY ./tailwind.dynamic.config.js ./tailwind.dynamic.config.js
COPY ./tailwind.application.config.js ./tailwind.application.config.js
COPY ./app/javascript ./app/javascript
COPY ./app/views ./app/views

RUN echo "gem 'shakapacker'" > Gemfile && ./bin/shakapacker

FROM ruby:3.4.7-slim AS ig_app

ENV RAILS_ENV=production
ENV BUNDLE_WITHOUT="development:test"
ENV OPENSSL_CONF=/etc/openssl_legacy.cnf

WORKDIR /app

RUN apt-get update -qq && apt-get install -y --no-install-recommends     libpq5 libvips42 libheif1 fontconfig curl     && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 2000 docuseal && useradd -u 2000 -g docuseal -s /bin/sh -m -d /home/docuseal docuseal

RUN echo '.include = /etc/ssl/openssl.cnf\n\n[provider_sect]\ndefault = default_sect\nlegacy = legacy_sect\n\n[default_sect]\nactivate = 1\n\n[legacy_sect]\nactivate = 1' >> /etc/openssl_legacy.cnf

COPY --chown=docuseal:docuseal ./Gemfile ./Gemfile.lock ./

RUN apt-get update -qq && apt-get install -y --no-install-recommends     build-essential git libpq-dev libyaml-dev gfortran libopenblas-dev cmake     && bundle install     && apt-get purge -y build-essential git libpq-dev libyaml-dev gfortran libopenblas-dev cmake     && apt-get autoremove -y     && rm -rf /var/lib/apt/lists/* ~/.bundle /usr/local/bundle/cache     && ruby -e "puts Dir['/usr/local/bundle/**/{spec,rdoc,resources/shared,resources/collation,resources/locales,resources/unicode_data/properties}'] + Dir['/usr/local/bundle/gems/*/{test,tests,examples,sample,misc,doc,docs}'] + Dir['/usr/local/bundle/gems/*/ext/**/*.{c,h,o,S}']" | xargs rm -rf

COPY --chown=docuseal:docuseal ./bin ./bin
COPY --chown=docuseal:docuseal ./app ./app
COPY --chown=docuseal:docuseal ./config ./config
COPY --chown=docuseal:docuseal ./db/migrate ./db/migrate
COPY --chown=docuseal:docuseal ./log ./log
COPY --chown=docuseal:docuseal ./lib ./lib
COPY --chown=docuseal:docuseal ./public ./public
COPY --chown=docuseal:docuseal ./tmp ./tmp
COPY --chown=docuseal:docuseal LICENSE LICENSE_ADDITIONAL_TERMS README.md Rakefile config.ru .version ./
COPY --chown=docuseal:docuseal .version ./public/version

COPY --chown=docuseal:docuseal --from=ig_download /fonts/GoNotoKurrent-Regular.ttf /fonts/GoNotoKurrent-Bold.ttf /fonts/DancingScript-Regular.otf /fonts/OFL.txt /fonts/LICENSE /fonts/
COPY --from=ig_download /pdfium-linux/lib/libpdfium.so /usr/lib/libpdfium.so
COPY --from=ig_download /pdfium-linux/licenses/pdfium.txt /usr/lib/libpdfium-LICENSE.txt
COPY --chown=docuseal:docuseal --from=ig_download /model.onnx /app/tmp/model.onnx
COPY --chown=docuseal:docuseal --from=ig_webpack /app/public/packs ./public/packs

RUN mkdir -p /app/public/fonts && ln -s /fonts/DancingScript-Regular.otf /app/public/fonts/ &&     mkdir -p /usr/share/fonts/noto && ln -s /fonts/GoNotoKurrent-Regular.ttf /usr/share/fonts/noto/ && ln -s /fonts/GoNotoKurrent-Bold.ttf /usr/share/fonts/noto/ && fc-cache -f &&     bundle exec bootsnap precompile -j 1 --gemfile app/ lib/ &&     chown -R docuseal:docuseal /app/tmp/cache

WORKDIR /data/docuseal
ENV HOME=/home/docuseal
ENV WORKDIR=/data/docuseal
ENV VIPS_MAX_COORD=17000

EXPOSE 3000
CMD ["/app/bin/bundle", "exec", "puma", "-C", "/app/config/puma.rb", "--dir", "/app"]
