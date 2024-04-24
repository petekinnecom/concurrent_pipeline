# ConcurrentPipeline

Define a bunch of steps, run them concurrently (or not), recover your data from any step along the way. Rinse, repeat as needed.

### Problem it solves

Occasionally I need to write a one-off script that has a number of independent steps, maybe does a bit of data aggregation, and reports some results at the end. In total, the script might take a long time to run. First, I'll write the full flow against a small set of data and get it working. Then I'll run it against the full dataset and find out 10 minutes later that I didn't handle a certain edge-case. So I rework the script and rerun ... and 10 minutes later learn that there was another edge-case I didn't handle.

The long feedback cycle here is painful and unnecessary. If I wrote all data to a file as it came in, when I encountered a failure, I could fix the handling in my code and resume where I left off, no longer needing to re-process all the steps that have already been completed successfully. This gem is my attempt to build a solution to that scenario.

### Installation

Hey it's a gem, you know what to do. Ugh, fine I'll write it: _Run `gem install concurrent_pipeline` to install or add it to your Gemfile!_

### Contributing

This code I've just written is already legacy code. Good luck!

### License

[WTFPL](https://www.wtfpl.net/txt/copying/)

## Guide and Code Examples

The text above was written by a human. The text below was written by Monsieur Claude. Is it correct? Yeah, I guess probably, sure, let's go with "yep" ok?

### Basic Example

Define a store with records, create a pipeline with processing steps, and run it:

```ruby
require "concurrent_pipeline"

# Define your data store
store = ConcurrentPipeline.store do
  storage(:yaml, dir: "/tmp/my_pipeline")

  record(:user) do
    attribute(:name)
    attribute(:processed, default: false)
  end
end

# Create some data
store.create(:user, name: "Alice")
store.create(:user, name: "Bob")

# Define processing pipeline
pipeline = ConcurrentPipeline.pipeline do
  processor(:sync)  # Run sequentially

  process(:user, processed: false) do |user|
    puts "Processing #{user.name}"
    store.update(user, processed: true)
  end
end

# Run it
pipeline.process(store)
```

### Async Processing

Use `:async` processor to run steps concurrently:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)  # Run concurrently

  process(:user, processed: false) do |user|
    # Each user processed in parallel
    sleep 1
    store.update(user, processed: true)
  end
end
```

Control concurrency and polling with optional parameters:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  # concurrency: max parallel tasks (default: 5)
  # enqueue_seconds: sleep between checking for new work (default: 0.1)
  processor(:async, concurrency: 10, enqueue_seconds: 0.5)

  process(:user, processed: false) do |user|
    # Up to 10 users processed concurrently
    expensive_api_call(user)
    store.update(user, processed: true)
  end
end
```

### Custom Methods on Records

Records can have custom methods defined in the record block:

```ruby
store = ConcurrentPipeline.store do
  storage(:yaml, dir: "/tmp/my_pipeline")

  record(:user) do
    attribute(:first_name)
    attribute(:last_name)
    attribute(:age)

    def full_name
      "#{first_name} #{last_name}"
    end

    def adult?
      age >= 18
    end
  end
end

store.create(:user, first_name: "Alice", last_name: "Smith", age: 25)
user = store.all(:user).first
puts user.full_name  # => "Alice Smith"
puts user.adult?     # => true
```

### Filtering Records

Use `where` to filter records, or pass filters directly to `process`:

```ruby
# Manual filtering
pending_users = store.where(:user, processed: false, active: true)

# Filter with lambdas/procs for custom logic
even_ids = store.where(:user, id: ->(id) { id.to_i.even? })
adults = store.where(:user, age: ->(age) { age >= 18 })

# Combine regular values with lambda filters
active_adults = store.where(:user, active: true, age: ->(age) { age >= 18 })

# Or use filters in pipeline
pipeline = ConcurrentPipeline.pipeline do
  processor(:sync)

  # Old style: pass a lambda
  process(-> { store.all(:user).select(&:active?) }) do |user|
    # ...
  end

  # New style: pass record name and filters
  process(:user, processed: false, active: true) do |user|
    # ...
  end
end
```

### Error Handling

When errors occur during async processing, they're collected and the pipeline returns `false`:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(:user, processed: false) do |user|
    raise "Something went wrong with #{user.name}" if user.name == "Bob"
    store.update(user, processed: true)
  end
end

result = pipeline.process(store)

unless result
  puts "Pipeline failed!"
  pipeline.errors.each { |error| puts error.message }
end
```

### Recovering from Failures

The store automatically versions your data. If processing fails, fix your code and restore from where you left off:

```ruby
# First run - fails partway through
store = ConcurrentPipeline.store do
  storage(:yaml, dir: "/tmp/my_pipeline")

  record(:user) do
    attribute(:name)
    attribute(:email)
    attribute(:email_sent, default: false)
  end
end

5.times { |i| store.create(:user, name: "User#{i}") }

pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(:user, email_sent: false) do |user|
    # Oops, forgot to handle missing emails
    email = fetch_email_for(user.name)  # Might return nil!
    send_email(email)  # This will fail if email is nil
    store.update(user, email: email, email_sent: true)
  end
end

pipeline.process(store)  # Some succeed, some fail

# Check what versions exist
store.versions.each_with_index do |version, i|
  puts "Version #{i}: #{version.all(:user).count { |u| u.email_sent }} emails sent"
end

# Fix the code and restore from last version
last_version = store.versions.first
restored_store = last_version.restore

# Now run with fixed logic
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(:user, email_sent: false) do |user|
    email = fetch_email_for(user.name) || "default@example.com"  # Fixed!
    send_email(email)
    restored_store.update(user, email: email, email_sent: true)
  end
end

pipeline.process(restored_store)  # Only processes remaining users
```

### Storage Structure

When using YAML storage, data is stored in a simple, human-readable file structure:

```
/tmp/my_pipeline/
├── data.yml              # Current state (always up-to-date)
└── versions/
    ├── 0001.yml          # Historical version 1
    ├── 0002.yml          # Historical version 2
    └── 0003.yml          # Historical version 3
```

- **`data.yml`**: Contains the most recent state of your data. You can inspect this file at any time to see the current state.
- **`versions/`**: Contains snapshots of previous versions. Each file is a complete snapshot at that point in time.

When you restore to a previous version, that version is copied to `data.yml` and any versions after it are deleted. You can then continue working from that restored state.

### Running Shell Commands

The `Shell` class helps run external commands within your pipeline. It exists because running shell commands in Ruby can be tedious - you need to capture stdout, stderr, check exit status, and handle failures. Shell simplifies this.

Available in process blocks via the `shell` helper:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:sync)

  process(:repository, cloned: false) do |repo|
    # Shell.run returns a Result with stdout, stderr, success?, command
    result = shell.run("git clone #{repo.url} /tmp/#{repo.name}")

    if result.success?
      puts result.stdout
      store.update(repo, cloned: true)
    else
      puts "Failed: #{result.stderr}"
    end
  end
end
```

Use `run!` to raise on failure:

```ruby
process(:repository, cloned: false) do |repo|
  # Raises error if command fails, returns stdout if success
  output = shell.run!("git clone #{repo.url} /tmp/#{repo.name}")
  store.update(repo, cloned: true, output: output)
end
```

Stream output in real-time with a block:

```ruby
process(:project, built: false) do |project|
  shell.run("npm run build") do |stream, line|
    puts "[#{stream}] #{line}"
  end
  store.update(project, built: true)
end
```

Use outside of pipelines by calling directly:

```ruby
# Check if a command succeeds
result = ConcurrentPipeline::Shell.run("which docker")
docker_installed = result.success?

# Get output or raise
version = ConcurrentPipeline::Shell.run!("ruby --version")
puts version  # => "ruby 3.2.9 ..."
```

### Multiple Processing Steps

Chain multiple steps together - each step processes what the previous step created:

```ruby
store = ConcurrentPipeline.store do
  storage(:yaml, dir: "/tmp/my_pipeline")

  record(:company) do
    attribute(:name)
    attribute(:fetched, default: false)
  end

  record(:employee) do
    attribute(:company_name)
    attribute(:name)
    attribute(:processed, default: false)
  end
end

store.create(:company, name: "Acme Corp")
store.create(:company, name: "Tech Inc")

pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  # Step 1: Fetch employees for each company
  process(:company, fetched: false) do |company|
    employees = api_fetch_employees(company.name)
    employees.each do |emp|
      store.create(:employee, company_name: company.name, name: emp)
    end
    store.update(company, fetched: true)
  end

  # Step 2: Process each employee
  process(:employee, processed: false) do |employee|
    send_welcome_email(employee.name)
    store.update(employee, processed: true)
  end
end

pipeline.process(store)
```

### Final words

That's it, you've reached THE END OF THE INTERNET.
