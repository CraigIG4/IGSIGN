# frozen_string_literal: true

require 'rails_helper'

RSpec.describe IgsignSigningThrottleMiddleware do
  let(:inner_app) { ->(_env) { [200, {}, ['OK']] } }
  let(:middleware) { described_class.new(inner_app) }

  def env_for(path, ip: '1.2.3.4')
    Rack::MockRequest.env_for(path, 'REMOTE_ADDR' => ip)
  end

  # Stub Redis so tests don't need a live Redis connection.
  def stub_redis(count)
    allow(Sidekiq).to receive(:redis).and_yield(double('redis', call: count))
  end

  describe 'non-signing paths' do
    it 'passes /agreements through without counting' do
      expect(Sidekiq).not_to receive(:redis)
      status, = middleware.call(env_for('/agreements'))
      expect(status).to eq(200)
    end

    it 'passes /admin/templates through without counting' do
      expect(Sidekiq).not_to receive(:redis)
      status, = middleware.call(env_for('/admin/templates'))
      expect(status).to eq(200)
    end
  end

  describe 'signing paths /s/ and /d/' do
    it 'passes /s/:slug through when under the limit' do
      stub_redis(1)
      status, = middleware.call(env_for('/s/abc123'))
      expect(status).to eq(200)
    end

    it 'passes /d/:slug through when under the limit' do
      stub_redis(50)
      status, = middleware.call(env_for('/d/xyz456'))
      expect(status).to eq(200)
    end

    it 'returns 429 when count exceeds LIMIT' do
      stub_redis(described_class::LIMIT + 1)
      status, headers, body = middleware.call(env_for('/s/abc123'))
      expect(status).to eq(429)
      expect(headers['Retry-After']).to eq(described_class::WINDOW.to_s)
      expect(body.first).to include('Too many requests')
    end

    it 'passes through when Redis raises (fail open)' do
      allow(Sidekiq).to receive(:redis).and_raise(StandardError, 'connection refused')
      status, = middleware.call(env_for('/s/abc123'))
      expect(status).to eq(200)
    end

    it 'uses X-Forwarded-For IP when present' do
      allow(Sidekiq).to receive(:redis) do |&block|
        redis = double('redis')
        # Key should incorporate the forwarded IP, not REMOTE_ADDR
        allow(redis).to receive(:call) do |cmd, key, *_args|
          expect(key).to include('5.6.7.8') if cmd == 'INCR'
          1
        end
        block.call(redis)
      end
      env = env_for('/s/abc', ip: '127.0.0.1')
      env['HTTP_X_FORWARDED_FOR'] = '5.6.7.8, 127.0.0.1'
      middleware.call(env)
    end
  end
end
