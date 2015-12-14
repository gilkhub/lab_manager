require 'spec_helper'
require 'rack/test'
require 'sidekiq/testing'
require 'lab_manager/app'

describe 'Computes' do
  Sidekiq::Testing.fake!

  include Rack::Test::Methods

  def app
    LabManager::App.new
  end

  describe 'GET /' do
    it 'returns empty list when no computes exists' do
      get '/computes'
      expect(last_response.status).to eq 200
      expect(MultiJson.load(last_response.body)).to eq []
    end

    describe 'filters' do
      let!(:c1) { create(:compute, provider_name: 'v_sphere', name: 'one') }
      let!(:c2) { create(:compute, provider_name: 'static_machine', name: 'two') }

      it 'returns all computes when no filter given' do
        get '/computes'
        expect(last_response.status).to eq 200
        expect(last_response.body).to eq [c1, c2].to_json
      end

      it 'returns computes filtered by name' do
        get '/computes?name=one'
        expect(last_response.status).to eq 200
        expect(last_response.body).to eq [c1].to_json
      end

      it 'returns computes filtered by provider_name' do
        get '/computes?provider_name=static_machine'
        expect(last_response.status).to eq 200
        expect(last_response.body).to eq [c2].to_json
      end

      it 'returns computes filtered by state' do
        c1.update_column(:state, 'running')
        get '/computes?state=running'
        expect(last_response.status).to eq 200
        expect(last_response.body).to eq [c1].to_json
      end

      it 'returns computes filtered by array state' do
        c1.update_column(:state, 'running')
        get '/computes?state[]=running&state[]=created'
        expect(last_response.status).to eq 200
        expect(last_response.body).to eq [c2, c1].to_json
      end
    end
  end

  describe 'POST /computes' do
    it 'returns 422 when unknown provider is specified' do
      post '/computes', provider_name: 'non-exist-provider', name: 'my_name'
      expect(last_response.status).to eq 422
    end

    it 'creates compute' do
      post '/computes', provider_name: 'static_machine', name: 'my_name'
      expect(last_response.status).to eq 200
      response = MultiJson.load(last_response.body)
      expect(response['state']).to eq 'created'
      expect(response['name']).to eq 'my_name'
      expect(response['provider_name']).to eq 'static_machine'
    end
  end

  describe 'GET /computes/:id' do
    let!(:c1) { create(:compute, provider_name: 'v_sphere', name: 'one') }

    it 'returns 404 for non-exist ID' do
      get '/computes/123456'
      expect(last_response.status).to eq 404
    end

    it 'returns the specified compute' do
      get "/computes/#{c1.id}", cached: 'false'
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq c1.to_json
    end

    it 'calls reload and returns the specified compute (cached==true)' do
      allow_any_instance_of(::Compute).to receive(:reload_provider_data) { true }
      get "/computes/#{c1.id}", cached: 'true'
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq c1.to_json
    end
  end

  describe 'GET /computes/:ids' do
    let!(:c1) { create(:compute, provider_name: 'v_sphere', name: 'one') }
    let!(:c2) { create(:compute, provider_name: 'v_sphere', name: 'two') }

    it 'returns 404 for not-existing ID' do
      get "/computes/#{c1.id},#{c2.id},34455321344"
      expect(last_response.status).to eq 404
    end

    it 'returns 404 for not-numeral IDs' do
      get '/computes/abcd,efgh,ijklm'
      expect(last_response.status).to eq 404
    end

    it 'returns the specified computes' do
      get "/computes/#{c1.id},#{c2.id}", cached: 'false'
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq [c1, c2].to_json
    end

    it 'calls reload and returns the specified computes (cached==true)' do
      allow_any_instance_of(::Compute).to receive(:reload_provider_data) { true }
      get "/computes/#{c1.id},#{c2.id}", cached: 'true'
      expect(last_response.status).to eq 200
      expect(last_response.body).to eq [c1, c2].to_json
    end
  end

  describe 'GET /computes/:id/actions' do
    let!(:compute) { create(:compute, provider_name: 'v_sphere', name: 'one') }

    it 'returns 404 when compute not found' do
      get '/computes/123456/actions'
      expect(last_response.status).to eq 404
    end

    it 'returns empty json array when no actions exist' do
      get "/computes/#{compute.id}/actions"
      expect(last_response.status).to eq 200
      expect(JSON.load(last_response.body)).to eq []
    end

    it 'returns json array with actions' do
      compute.actions.create!(command: :poweroff_vm)
      compute.actions.create!(command: :poweron_vm)
      get "/computes/#{compute.id}/actions"
      body = last_response.body
      expect(last_response.status).to eq 200
      expect(JSON.load(body).size).to eq 2
      expect(body).to eq compute.actions.to_json
    end
  end

  describe 'actions' do
    let!(:compute) { create(:compute, provider_name: 'v_sphere', name: 'one') }

    [
      # [:method, :url, :command]
      [:delete, '/computes/%d',           'terminate_vm'],
      [:put,    '/computes/%d/power_on',  'poweron_vm'],
      [:put,    '/computes/%d/power_off', 'poweroff_vm'],
      [:put,    '/computes/%d/shutdown',  'shutdown_vm'],
      [:put,    '/computes/%d/reboot',    'reboot_vm'],
      [:put,    '/computes/%d/execute',    'execute_vm']
    ].each do |method, url, command|
      it 'returns 404 for non-exist ID' do
        send(method, '/computes/123456')
        expect(last_response.status).to eq 404
      end

      it "creates and schedule '#{command}' action for compute", sidekiq: true do
        expect do
          send(method, url % compute.id)
        end.to change(LabManager::ActionWorker.jobs, :size).by(1)
        expect(last_response.status).to eq 200
        result = MultiJson.load(last_response.body)
        expect(result['command']).to eq command
        expect(result['state']).to eq 'queued'
      end
    end

    describe 'reboot action' do
      it 'reboot returns 422 with invalid type param' do
        put "/computes/#{compute.id}/reboot", type: 'invalid-type'
        expect(last_response.status).to eq 422
      end

      it 'accepts type soft, hard and managed' do
        put "/computes/#{compute.id}/reboot", type: 'soft'
        expect(last_response.status).to eq 200
        put "/computes/#{compute.id}/reboot", type: 'hard'
        expect(last_response.status).to eq 200
        put "/computes/#{compute.id}/reboot", type: 'managed'
        expect(last_response.status).to eq 200
      end

      it 'reboot set default type managed' do
        put "/computes/#{compute.id}/reboot"
        expect(last_response.status).to eq 200
        result = MultiJson.load(last_response.body)
        expect(result['payload']['type']).to eq 'managed'
      end
    end

    it 'execute pass command, user and password to action' do
      headers = { 'CONTENT_TYPE' => 'application/json' }
      payload = {
        command: 'echo 1',
        user: 'user',
        password: 'password',
        args: [1, 2, 3],
        working_dir: '/'
      }

      put "/computes/#{compute.id}/execute", payload.to_json, headers

      expect(last_response.status).to eq 200
      result = MultiJson.load(last_response.body)
      expect(result['payload']).to eq(
        'command' => 'echo 1',
        'user' => 'user',
        'password' => 'password',
        'args' => [1, 2, 3],
        'working_dir' => '/'
      )
    end
  end

  describe 'snapshots' do
    let(:compute) { create(:compute, provider_name: 'v_sphere', name: 'one') }

    describe 'GET /compute/:id/snapshosts' do
      it 'returns status code 200 when compute exists' do
        get "/computes/#{compute.id}/snapshots"
        expect(last_response.status).to eq 200
      end

      it 'returns status code 404 when compute does not exitsts' do
        get '/computes/404/snapshots'
        expect(last_response.status).to eq 404
      end

      it 'returns empty list when no spatshots exists' do
        get "/computes/#{compute.id}/snapshots"
        expect(MultiJson.load(last_response.body)).to eq []
      end

      it 'returns all snapshots' do
        s1 = compute.snapshots.create!(name: 'Snap1')
        s2 = compute.snapshots.create!(name: 'Snap2')
        get "/computes/#{compute.id}/snapshots"
        response = MultiJson.load(last_response.body)
        expect(response).to eq MultiJson.load([s1, s2].to_json)
      end
    end

    describe 'GET /computes/:compute_id/snapshot/:id' do
      let(:snapshot) { compute.snapshots.create!(name: 'Snap1') }

      it 'returns status code 404 when compute does not exist' do
        get "/computes/404/snapshots/#{snapshot.id}"
        expect(last_response.status).to eq 404
      end

      it 'returns status code 404 when snapshot does not exist' do
        get "/computes/#{snapshot.compute.id}/snapshots/123"
        expect(last_response.status).to eq 404
      end

      it 'returns status code 200 when compute exists' do
        get "/computes/#{snapshot.compute.id}/snapshots/#{snapshot.id}"
        expect(last_response.status).to eq 200
      end
    end

    describe 'POST /computes/:compute_id/snaphosts' do
      it 'requires name param to be specified' do
        post "/computes/#{compute.id}/snapshots"
        expect(last_response.status).to eq 422
        post "/computes/#{compute.id}/snapshots", 'name' => ''
        expect(last_response.status).to eq 422
        post "/computes/#{compute.id}/snapshots", 'name' => 'correct'
        expect(last_response.status).to eq 200
      end

      it 'only name is allowed param' do
        post "/computes/#{compute.id}/snapshots", 'name' => '1', 'x' => 1
        expect(last_response.status).to eq 422
        response = MultiJson.load(last_response.body)
        expect(response['message']).to match(/only.*is allowed/)
      end

      it 'creates snapshot model and returns it' do
        post "/computes/#{compute.id}/snapshots", 'name' => 'correct'
        expect(last_response.status).to eq 200
        response = MultiJson.load(last_response.body)
        snapshot = compute.snapshots.first
        expect(response).to eq MultiJson.load(snapshot.to_json)
      end

      it 'assign name to snapshot model' do
        post "/computes/#{compute.id}/snapshots", 'name' => 'correct'
        snapshot = compute.snapshots.first
        expect(snapshot.name).to eq 'correct'
      end

      it 'creates action for take_snapshot_vm' do
        post "/computes/#{compute.id}/snapshots", 'name' => 'correct'
        expect(last_response.status).to eq 200
        response = MultiJson.load(last_response.body)
        action = compute.actions.last
        expect(action.command).to eq 'take_snapshot_vm'
        expect(action.payload[:snapshot_id]).to eq response['id']
        expect(action.payload[:name]).to eq 'correct'
      end

      it 'schedules sidekiq job for action', sidekiq: true do
        expect do
          post "/computes/#{compute.id}/snapshots", 'name' => 'correct'
          expect(last_response.status).to eq 200
        end.to change(LabManager::ActionWorker.jobs, :size).by(1)
      end
    end

    describe 'POST /computes/:compute_id/snaphosts/:snapshot_id/revert' do
      let(:snapshot) { compute.snapshots.create!(name: 'Snap1') }

      it 'returns 404 when compute not found' do
        post "/computes/#{compute.id + 200}/snapshots/#{snapshot.id}/revert"
        expect(last_response.status).to eq 404
      end

      it 'returns 404 when snapshot not found' do
        post "/computes/#{compute.id}/snapshots/#{snapshot.id + 100}/revert"
        expect(last_response.status).to eq 404
      end

      context 'when params are OK' do
        it 'returns 200' do
          post "/computes/#{compute.id}/snapshots/#{snapshot.id}/revert"
          expect(last_response.status).to eq 200
        end

        it 'creates the action' do
          expect_any_instance_of(::Compute).to receive(:actions) do
            double('fake acction', create!: { id: 899_999 })
          end

          post "/computes/#{compute.id}/snapshots/#{snapshot.id}/revert"
        end

        it 'returns the created action' do
          allow_any_instance_of(::Compute).to receive(:actions) do
            double('fake acction', create!: { id: 899_999 })
          end

          post "/computes/#{compute.id}/snapshots/#{snapshot.id}/revert"
        end
      end

      it 'schedules sidekiq job for action', sidekiq: true do
        expect do
          post "/computes/#{compute.id}/snapshots/#{snapshot.id}/revert"
          expect(last_response.status).to eq 200
        end.to change(LabManager::ActionWorker.jobs, :size).by(1)
      end
    end
  end

  describe 'GET /computes/:compute_id/processes' do
    let(:compute) { create(:compute, provider_name: 'v_sphere', name: 'one') }

    it 'returns 404 when compute not found' do
      get "/computes/#{compute.id + 200}/processes"
      expect(last_response.status).to eq 404
    end

    it 'returns 404 when user not specified' do
      get "/computes/#{compute.id}/processes", 'user' => 'fooo'
      expect(last_response.status).to eq 422
    end

    it 'returns the created action' do
      expect_any_instance_of(::Compute).to receive(:actions) do
        double('fake acction', create!: { id: 899_999 })
      end

      get "/computes/#{compute.id}/processes", 'user' => 'fooo', 'password' => 'foo'
      expect(last_response.status).to eq 200
      expect(MultiJson.load(last_response.body).to_hash['id']).to eq 899_999
    end
  end

  describe 'POST /computes/:id/upload' do
    let(:compute) { create(:compute, provider_name: 'v_sphere', name: 'one') }

    it 'returns 422 when compute not found' do
      get "/computes/#{compute.id + 200}/upload"
      expect(last_response.status).to eq 404
    end

    it 'returns 422 when user not specified' do
      get "/computes/#{compute.id}/upload", 'user' => 'fooo'
      expect(last_response.status).to eq 422
    end

    it 'returns 422 when user not specified' do
      get "/computes/#{compute.id}/upload", 'password' => 'fooo'
      expect(last_response.status).to eq 422
    end

    it 'returns 422 when user not specified' do
      get "/computes/#{compute.id}/upload", 'user' => 'fake_user', 'password' => 'fake_password'
      expect(last_response.status).to eq 422
    end

    it 'returns the created action and schedules the Sidekiq job', sidekiq: true do
      expect do
          post "/computes/#{compute.id}/upload", 'user' => 'fake_user', 'password' => 'fake_password', 'guest_file_path' => "/path/to/nowhere"
          expect(last_response.status).to eq 200
        end.to change(LabManager::ActionWorker.jobs, :size).by(1)      
      end
    end
  end
end
