# Services Sync

Application to sync updates between Zoom and Salesforce

## Getting Started

Run ./setup.sh to initialize your environment.

Update .env and config/smtp_config.yml with settings appropriate for your environment.

### Prerequisites

Have Ruby 2.5.0 installed. See setup.sh for instructions. Or do the following:

### Installing

```
sudo apt-get install software-properties-common
sudo apt-add-repository -y ppa:rael-gc/rvm
sudo apt-get update
sudo apt-get install rvm
bash ./setup.sh
```

## Running Sync Jobs

Start the long-running process to listen for Salesforce updates and sync to Zoom
```
ruby ./start_salesforce_sync_job.rb
```

Run the nightly sync job
```
ruby ./run_nightly_sync_job.rb
```

## Logging and Notification

* Email is currently disabled from sending but will be logged to /log/email.log.
* Nightly sync logging is at /log/nightly_sync.log.
* General information about the sync process is logged to /log/sync.log.

## Example Interactive Console Usage

Run nightly script
```
irb -r ./lib/salesforce_zoom_sync.rb
# run nightly script
SalesforceZoomSync.new
```

Start service to register for Salesforce push notifications and update Zoom
```
irb -r ./lib/push_sync.rb
# start push updates (this will block)
PushSync.new
```
Interactive Zoom examples
```
require 'awesome_print'
zs = ZoomSync.new
all_users = zs.all_users
ap all_users
# get meeting details
meeting_details = zs.intro_call_details
ap meeting_details
# call a manual endpoint
daily_report = call(endpoint: 'report/daily/', params: { year: date.year, month: date.month })
ap daily_report
```
Interactive Salesforce examples
```
require 'awesome_print'
sf = SalesforceSync.new
all_users = sf.all_contacts
ap all_users
# manual query
meeting_details = sf.client.query("SELECT Id, FirstName, LastName, Birthdate, Email, Intro_Call_RSVP_Date__c FROM Contact")
```

## Deployment

TODO

## Built With

TODO

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details
