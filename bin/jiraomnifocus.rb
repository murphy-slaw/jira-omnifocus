#!/usr/local/bin/ruby
require 'app_conf'
require 'appscript'
require 'rubygems'
require 'net/http'
require 'json'

# This method gets all issues that are assigned to your USERNAME and whos status isn't Closed or Resolved.  It returns a Hash where the key is the Jira Ticket Key and the value is the Jira Ticket Summary.
def get_issues
  jira_issues = Hash.new
  # This is the REST URL that will be hit.  Change the jql query if you want to adjust the query used here
  uri = URI(@config[:jira_base_url] + '/rest/api/2/search?jql=assignee+%3D+currentUser()+AND+status+not+in+(Closed,Done)') 

  Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    request = Net::HTTP::Get.new(uri.request_uri)
    request.basic_auth @config[:username], @config[:password]
    response = http.request request
    # If the response was good, then grab the data
    if response.code =~ /20[0-9]{1}/
        data = JSON.parse(response.body)
        data["issues"].each do |item|
          jira_id = item["key"]
          jira_issues[jira_id] = item["fields"]["summary"]
        end    
    else
     raise StandardError, "Unsuccessful response code " + response.code
    end
  end
  return jira_issues
end

# This method adds a new Task to OmniFocus based on the new_task_properties passed in
def add_task(omnifocus_document, new_task_properties)
  # If there is a passed in OF project name, get the actual project object
  if new_task_properties["project"]
    proj_name = new_task_properties["project"]
    proj = omnifocus_document.flattened_tasks[proj_name]
  end

  # If there is a passed in OF context name, get the actual context object
  if new_task_properties['context']
    ctx_name = new_task_properties["context"]
    ctx = omnifocus_document.flattened_contexts[ctx_name]
  end
  
  # Do some task property filtering.  I don't know what this is for, but found it in several other scripts that didn't work...
  tprops = new_task_properties.inject({}) do |h, (k, v)|
    h[:"#{k}"] = v
    h
  end

  # Remove the project property from the new Task properties, as it won't be used like that.
  tprops.delete(:project)
  # Update the context property to be the actual context object not the context name
  tprops[:context] = ctx if new_task_properties['context']

  # You can uncomment this line and comment the one below if you want the tasks to end up in your Inbox instead of a specific Project
#  new_task = omnifocus_document.make(:new => :inbox_task, :with_properties => tprops)

  # Make a new Task in the Project
  proj.make(:new => :task, :with_properties => tprops)
  
  puts "task created"
  return true
end

# This method is responsible for getting your assigned Jira Tickets and adding them to OmniFocus as Tasks
def add_jira_tickets_to_omnifocus ()
  # Get the open Jira issues assigned to you
  results = get_issues
  if results.nil?
    puts "No results from Jira"
    exit
  end

  # Get the OmniFocus app and main document via AppleScript
  omnifocus_app = Appscript.app.by_name("OmniFocus")
  omnifocus_document = omnifocus_app.default_document

  existing_tasks = omnifocus_document.flattened_tasks

  # Iterate through resulting issues.
  results.each do |jira_id, summary|
    # Create the task name by adding the ticket summary to the jira ticket key
    task_name = "#{jira_id}: #{summary}"
    # Create the task notes with the Jira Ticket URL
    task_notes = "#{@config[:jira_base_url]}/browse/#{jira_id}"

    exists = existing_tasks.get.find { |t| t.name.get == task_name }
    next if exists

    # Build properties for the Task
    @props = {}
    @props['name'] = task_name
    @props['project'] = @config[:default_project]
    @props['context'] = @config[:default_context]
    @props['note'] = task_notes
    @props['flagged'] = @config[:flagged]
    add_task(omnifocus_document, @props)
  end
end

def mark_resolved_jira_tickets_as_complete_in_omnifocus ()
  # get tasks from the project
  omnifocus_app = Appscript.app.by_name("OmniFocus")
  omnifocus_document = omnifocus_app.default_document
  ctx = omnifocus_document.flattened_contexts[@config[:default_context]]
  ctx.tasks.get.find.each do |task|
    if task.note.get.match(@config[:jira_base_url])
      # try to parse out jira id      
      full_url= task.note.get
      jira_id=full_url.sub(@config[:jira_base_url]+"/browse/","")
      # check status of the jira
      uri = URI(@config[:jira_base_url] + '/rest/api/2/issue/' + jira_id)

      Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        #http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        request = Net::HTTP::Get.new(uri.request_uri)
        request.basic_auth @config[:username], @config[:password]
        response = http.request request

        if response.code =~ /20[0-9]{1}/
            data = JSON.parse(response.body)
            resolution = data["fields"]["resolution"]
            if resolution != nil
              # if resolved, mark it as complete in OmniFocus
              task.completed.set(true)
            end
        else
         raise StandardError, "Unsuccessful response code " + response.code + " for issue " + issue
        end
      end
    end
  end
end

def app_is_running(app_name)
  `ps aux` =~ /#{app_name}/ ? true : false
end

def main ()
   config_dir = File.dirname(__FILE__)
   config_file = config_dir + "/config.yml"
   @config = AppConf.new
   @config.load(config_file)
   if app_is_running("OmniFocus")
	  add_jira_tickets_to_omnifocus
	  mark_resolved_jira_tickets_as_complete_in_omnifocus
   end
end

main
