require 'sinatra/base'
require 'sass'
require 'json'
require 'slim'
require 'sprockets'
require 'compass'
require 'sprockets-sass'
require 'sprockets-helpers'
require 'bundler'
require 'open3'
require 'date'
require 'digest/sha2'
require 'securerandom'

require_relative 'helpers/repository'

module AwestructWebEditor
  class PublicApp < Sinatra::Base
    set :sprockets, Sprockets::Environment.new(root)
    enable :sessions

    configure do
      # Setup Sprockets
      Sprockets::Helpers.configure do |config|
        config.environment = sprockets

        %w(sass javascripts images fonts).each do |dir|
          sprockets.append_path File.join(root, 'assets', dir)
        end

        config.debug = true if development?

      end
    end

    configure :development do
      require 'sinatra/reloader'
      register Sinatra::Reloader
      also_reload 'app.rb'
      also_reload 'models/**/*.rb'
      set :raise_errors, true
      enable :logging, :dump_errors, :raise_errors
    end

    configure :production do
      #sprockets.js_compressor = :uglifier
      sprockets.css_compressor = :scss
    end

    before %r{^\/(repo|preview)(\/[\w]+)*} do
      unless session['token']
        session['token'] = (Digest::SHA512.new << SecureRandom.uuid << SecureRandom.random_bytes).to_s
      end
      # check the token they have sent
      if cookies['token']
        request_token = env['token']
        request_time = env['time']
        unless request_token == (Digest::SHA512.new << "#{session['token']}#{request_time}").to_s
          halt 401
        end
      else
        cookies['token'] = (Digest::SHA512.new << "#{session['token']}").to_s
      end
    end

    after do
      time = DateTime.now.iso8601
      response.headers['time'] = time
      response.headers['token'] = (Digest::SHA512.new << "#{cookies['token']}#{time}").to_s
    end

    # Views

    get '/' do
      slim :index
    end

    get '/partials/*.*' do |basename, ext|
      slim "partials/#{basename}".to_sym
    end

    # Application API

    # Git related APIs
    post '/repo/:repo_name/change_set' do |repo_name|
      create_repo(repo_name).create_branch params[:name]
    end

    post '/repo/:repo_name/commit' do |repo_name|
      unless create_repo(repo_name).commit(params[:message]).nil?
        [200, 'Success']
      else
        [500, 'Error committing']
      end
    end

    post '/repo/:repo_name/pull_latest' do |repo_name|
      repo = create_repo(repo_name)
      repo.rebase(params.include? :overwrite)
    end

    # Repo APIs
    post '/repo/:repo_name/push' do |repo_name|
      repo = create_repo(repo_name)
      repo.push
      repo.pull_request params[:title], params[:message]
    end

    get '/repo' do
      repo_base = ENV['RACK_ENV'] =~ /test/ ? 'tmp/repos' : 'repos'
      return_structure = {}
      Dir[repo_base + '/*'].each do |f|
        if File.directory? f
          basename = File.basename f
          return_structure[basename] = { 'links' => [AwestructWebEditor::Link.new({ :url => url("/repo/#{basename}"),
                                                                                    :text => f,
                                                                                    :method => 'GET' })] }
        end
      end
      [200, JSON.dump(return_structure)]
    end

    # File related APIs

    get '/repo/:repo_name' do |repo_name|
      additional_allows = params[:allow] || ''
      files = create_repo(repo_name).all_files([Regexp.compile(additional_allows)])
      return_links = {}
      files.each do |f|
        links = []

        unless f[:directory]
          links = links_for_file(f, repo_name)
        end

        if f[:path_to_root] =~ /\./
          return_links[f[:location]] = { :links => links, :directory => f[:directory], :children => {},
                                         :path => File.join(f[:path_to_root], f[:location]) }
        else
          directory_paths = f[:path_to_root].split(File::SEPARATOR)
          final_location = return_links[directory_paths[0]]
          directory_paths.delete(directory_paths[0])
          directory_paths.each { |path| final_location = final_location[:children][path] } unless directory_paths.nil?
          final_location[:children][f[:location]] = { :links => links, :directory => f[:directory], :children => {},
                                                      :path => File.join(f[:path_to_root], f[:location]) }
        end
      end
      [200, JSON.dump(return_links)]
    end

    get '/repo/:repo_name/*' do |repo_name, path|
      repo = create_repo(repo_name)
      json_return = { :content => repo.file_content(path), :links => links_for_file(repo.file_info(path), repo_name) }
      [200, JSON.dump(json_return)]
    end

    post '/repo/:repo_name/*' do |repo_name, path|
      save_or_create(repo_name, path)
    end

    put '/repo/:repo_name/*' do |repo_name, path|
      save_or_create(repo_name, path)
    end

    delete '/repo/:repo_name/*' do |repo_name, path|
      result = create_repo(repo_name).remove_file path
      result ? [200] : [500]
    end

    # Preview APIs

    get '/preview/:repo_name' do |repo_name|
      retrieve_rendered_file(create_repo repo_name, 'index', 'html')
    end

    get '/preview/:repo_name/*.*' do |repo_name, path, ext|
      retrieve_rendered_file(create_repo repo_name, path, ext)
    end

    helpers do
      include Sprockets::Helpers
      include Sinatra::Cookies

      def create_repo(repo_name)
        AwestructWebEditor::Repository.new({ :name => repo_name })
      end

      def links_for_file(f, repo_name)
        links = []
        links << AwestructWebEditor::Link.new({ :url => url("/repo/#{repo_name}/#{f[:path_to_root]}/#{f[:location]}"), :text => f[:location], :method => 'GET' })
        links << AwestructWebEditor::Link.new({ :url => url("/repo/#{repo_name}/#{f[:path_to_root]}/#{f[:location]}"), :text => f[:location], :method => 'PUT' })
        links << AwestructWebEditor::Link.new({ :url => url("/repo/#{repo_name}/#{f[:path_to_root]}/#{f[:location]}"), :text => f[:location], :method => 'POST' })
        links << AwestructWebEditor::Link.new({ :url => url("/repo/#{repo_name}/#{f[:path_to_root]}/#{f[:location]}"), :text => f[:location], :method => 'DELETE' })
        links << AwestructWebEditor::Link.new({ :url => url("/repo/#{repo_name}/#{f[:path_to_root]}/#{f[:location]}/preview"), :text => "Preview #{f[:location]}", :method => 'GET' })
      end

      def save_or_create(repo_name, path)
        request.body.rewind # in case someone already read it
        repo = create_repo repo_name
        repo.save_file path, params[:content]

        retrieve_rendered_file(repo, path) unless ENV['RACK_ENV'] =~ /test/
      end

      def retrieve_rendered_file(repo, path)
        Bundler.with_clean_env do
          Open3.popen3("ruby exec_awestruct.rb --repo #{repo.name} --url '#{request.scheme}://#{request.host}' --profile development") do |stdin, stdout, stderr, thr|
            mapping = nil
            stdout.each_line do |line|
              if line.match(/^\{.*/)
                mapping = JSON.load line
              end
            end

            if !mapping.nil? && mapping.include?('/' + path)
              [200, File.open(File.join(repo.base_repository_path, '_site', mapping['/' + path]), 'r') { |f| f.readlines }]
            else
              [500, JSON.dump("Error: #{path} not rendered")]
            end
          end
        end
      end
    end
  end
end
