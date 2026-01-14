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

# Define your data store with inline schema definitions
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  record(:user) do
    schema(:users) do |t|
      t.string(:name)
      t.boolean(:processed, default: false)
    end
  end
end

# Create some data
store.transaction do
  store.user.create!(name: "Alice")
  store.user.create!(name: "Bob")
end

# Define processing pipeline
pipeline = ConcurrentPipeline.pipeline do
  processor(:sync)  # Run sequentially

  process(store.user.where(processed: false)) do |user|
    puts "Processing #{user.name}"
    user.update!(processed: true)
  end
end

# Run it
pipeline.process(store)
```

### Defining Record Schemas

The recommended approach is to define schemas directly inside record blocks. This keeps your table schema, custom methods, and validations all in one place:

```ruby
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  record(:user) do
    schema(:users) do |t|
      t.string(:first_name)
      t.string(:last_name)
      t.integer(:age)
      t.boolean(:processed, default: false)
    end

    validates :first_name, presence: true

    def full_name
      "#{first_name} #{last_name}"
    end

    def adult?
      age >= 18
    end
  end
end

store.transaction do
  store.user.create!(first_name: "Alice", last_name: "Smith", age: 25)
end

user = store.user.first
puts user.full_name  # => "Alice Smith"
puts user.adult?     # => true
```

This approach keeps related code together - the table schema, custom methods, and validations all in one record definition.

### Async Processing

Use `:async` processor to run steps concurrently:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)  # Run concurrently

  process(store.user.where(processed: false)) do |user|
    # Each user processed in parallel
    sleep 1
    user.update!(processed: true)
  end
end
```

Control concurrency and polling with optional parameters:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  # concurrency: max parallel tasks (default: 5)
  # enqueue_seconds: sleep between checking for new work (default: 0.1)
  processor(:async, concurrency: 10, enqueue_seconds: 0.5)

  process(store.user.where(processed: false)) do |user|
    # Up to 10 users processed concurrently
    expensive_api_call(user)
    user.update!(processed: true)
  end
end
```

### Using migrate for Schema Modifications

The `migrate` method is used when you need to modify an existing schema, such as when restoring from a previous version of your store and adding new columns or tables. Migrations defined this way are placed after inline schema definitions:

```ruby
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  # Existing record with inline schema
  record(:user) do
    schema(:users) do |t|
      t.string(:name)
      t.boolean(:processed, default: false)
    end
  end

  # Later, you need to add a new column to the existing table
  # This is useful when working with an existing database
  migrate do
    add_column(:users, :email, :string)
  end

  # Or add a completely new table not associated with a record
  migrate do
    create_table(:audit_logs) do |t|
      t.string(:action)
      t.integer(:user_id)
      t.timestamps
    end
  end
end
```

**When to use `migrate`:**
- Adding columns to tables that were created in a prior version of your script
- Removing or modifying columns in existing tables
- Creating additional tables not associated with a primary record
- Running data migrations or other one-time schema changes

**Migration order:**
- Inline `schema` calls are always processed first (prepended to the migration list)
- `migrate` calls are processed after all schemas (appended to the migration list)
- Each migration is tracked and only runs once

For new record definitions, prefer using the inline `schema` approach to keep related code together.

### Custom Methods on Records

Records can have custom methods defined alongside their schema. This was already shown in the "Defining Record Schemas" section above, but here's another example:

```ruby
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  record(:user) do
    schema(:users) do |t|
      t.string(:first_name)
      t.string(:last_name)
      t.integer(:age)
    end

    def full_name
      "#{first_name} #{last_name}"
    end

    def adult?
      age >= 18
    end
  end
end

store.transaction do
  store.user.create!(first_name: "Alice", last_name: "Smith", age: 25)
end
user = store.user.first
puts user.full_name  # => "Alice Smith"
puts user.adult?     # => true
```

### Inline Schema Definitions

You can define a record's schema directly inside the record block, combining the schema and custom methods in one place. Schema migrations defined this way are automatically placed at the front of the migration queue and use the table name as the migration version:

```ruby
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  # Define schema inline with the record
  record(:user) do
    schema(:users) do |t|
      t.string(:first_name)
      t.string(:last_name)
      t.integer(:age)
      t.boolean(:processed, default: false)
    end

    def full_name
      "#{first_name} #{last_name}"
    end

    def adult?
      age >= 18
    end
  end

  # Regular migrations are placed after inline schemas
  migrate do
    create_table(:other_table) do |t|
      t.string(:data)
    end
  end
end

# Use the record normally
store.transaction do
  store.user.create!(first_name: "Alice", last_name: "Smith", age: 25)
end

user = store.user.first
puts user.full_name  # => "Alice Smith"
puts user.adult?     # => true
```

**Migration Order:**
- Inline `schema` calls are prepended (added to the front of the migration list)
- Regular `migrate` calls are appended (added to the end of the migration list)
- Schema migrations use the table name as their version identifier

This approach keeps related code together - the table schema, custom methods, and validations all in one record definition.

### Defining Associations (belongs_to, has_many)

ConcurrentPipeline supports ActiveRecord associations like `belongs_to` and `has_many`. Because the store creates versioned copies of your data, association class names must be dynamically generated to work across different store versions. This is handled automatically through the `class_name` helper.

**Important:** When defining associations, you must explicitly specify the `foreign_key`, `class_name`, and `inverse_of` options:

```ruby
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  # Parent record
  record(:author) do
    schema(:authors) do |t|
      t.string(:name)
    end

    # has_many association
    has_many(
      :posts,
      foreign_key: :author_id,              # Required: specify the foreign key column
      class_name: class_name(:post),        # Required: dynamic class name for versions
      inverse_of: :author                   # Required: bidirectional association
    )
  end

  # Child record
  record(:post) do
    schema(:posts) do |t|
      t.string(:title)
      t.text(:content)
      t.integer(:author_id)                 # Foreign key column
    end

    # belongs_to association
    belongs_to(
      :author,
      class_name: class_name(:author),      # Required: dynamic class name for versions
      inverse_of: :posts                    # Required: bidirectional association
    )
  end
end

# Create data with associations
author = store.author.transaction do
  store.author.create!(name: "Jane Doe")
end

post1 = store.post.transaction do
  store.post.create!(
    title: "First Post",
    content: "Hello, World!",
    author_id: author.id
  )
end

post2 = store.post.transaction do
  store.post.create!(
    title: "Second Post",
    content: "More content",
    author_id: author.id
  )
end

# Use the associations
reloaded_author = store.author.find(author.id)
puts reloaded_author.posts.count              # => 2
puts reloaded_author.posts.first.title        # => "First Post"

reloaded_post = store.post.find(post1.id)
puts reloaded_post.author.name                # => "Jane Doe"

# Associations work across versions too!
v0_author = store.versions[0].author.find(author.id)
puts v0_author.posts.count                    # => 0 (no posts yet in version 0)

v1_author = store.versions[1].author.find(author.id)
puts v1_author.posts.count                    # => 1 (one post in version 1)

v2_author = store.versions[2].author.find(author.id)
puts v2_author.posts.count                    # => 2 (both posts in version 2)
```

**Why dynamic class names?** The store creates immutable snapshots of your data at each version. Each version needs its own set of model classes to prevent data from different versions from interfering with each other. The `class_name` helper generates the correct class name for each version automatically, allowing associations to work seamlessly across all versions of your data.

**Required Association Options:**
- `foreign_key`: The database column name storing the foreign key (must be explicitly specified)
- `class_name`: Use `class_name(:record_name)` helper to generate the correct versioned class name
- `inverse_of`: Specifies the reverse association for bidirectional relationships

### Filtering Records

Use ActiveRecord `where` to filter records:

```ruby
# ActiveRecord where clauses
pending_users = store.user.where(processed: false, active: true)

# Complex queries with ActiveRecord syntax
even_ids = store.user.where("id % 2 = 0")
adults = store.user.where("age >= ?", 18)

# Chain conditions
active_adults = store.user.where(active: true).where("age >= ?", 18)

# Use in pipeline
pipeline = ConcurrentPipeline.pipeline do
  processor(:sync)

  # Pass ActiveRecord relation directly
  process(store.user.where(processed: false, active: true)) do |user|
    # ...
  end
end
```

### Error Handling

When errors occur during async processing, they're collected and the pipeline returns `false`:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(store.user.where(processed: false)) do |user|
    raise "Something went wrong with #{user.name}" if user.name == "Bob"
    user.update!(processed: true)
  end
end

result = pipeline.process(store)

unless result
  puts "Pipeline failed!"
  pipeline.errors.each { |error| puts error.message }
end
```

### Assertions for Exit Conditions

Use the `assert` method within process blocks to verify exit conditions and protect against infinite loops. This is especially useful when delegating work to other classes:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(MyRecord.where(status: "ready")) do |record|
    # Delegate processing to another class
    SomeOtherClass.call(record)

    # Assert that the record's state actually changed
    # This protects against infinite loops if SomeOtherClass fails silently
    assert(record.status != "ready")
  end
end
```

**When to use assertions:**
- Verifying that external services or classes actually performed expected operations
- Preventing infinite loops when a record's state must change for processing to continue
- Catching silent failures in delegated code
- Ensuring critical invariants are maintained during processing

Failed assertions raise `ConcurrentPipeline::Errors::AssertionFailure` and stop processing for that record.

### Progress Tracking

Use the `before_process` hook to monitor pipeline execution in real-time. The hook receives a `step` object with information about each record being processed:

```ruby
pipeline = Pipeline.define do
  processor(:async)

  before_process do |step|
    puts "Processing: #{step.value.inspect}"
    puts "Queue size: #{step.queue_size}"
    puts "Label: #{step.label}" if step.label
  end

  process(store.user.where(processed: false)) do |user|
    user.update!(processed: true)
  end
end

pipeline.process(store)
```

**Step attributes:**
- `step.value` - The record being processed
- `step.queue_size` - Number of items remaining in the queue for this process step
- `step.label` - Optional label assigned to the process step

Use labels to distinguish between different processing steps:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  on_progress do |step|
    puts "Processing: #{step.label}"
    puts "#{step.queue_size} items remaining in this step"
  end

  process(store.company.where(fetched: false), label: "fetch_companies") do |company|
    employees = api_fetch_employees(company.name)
    employees.each { |emp| store.employee.create!(company_name: company.name, name: emp) }
    company.update!(fetched: true)
  end

  process(store.employee.where(processed: false), label: "process_employees") do |employee|
    send_welcome_email(employee.name)
    employee.update!(processed: true)
  end
end

pipeline.process(store)
```

The `before_process` hook is called before each record is processed, making it ideal for:
- Logging progress
- Updating progress bars
- Sending status updates
- Monitoring queue sizes
- Debugging pipeline execution

### Periodic Timer Hook

Use the `timer` hook to execute code periodically during pipeline processing. This is useful for status updates, logging, or monitoring:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  # Quick status updates every 2 seconds
  timer(2) do |stats|
    puts "Progress: #{stats.completed} completed, #{stats.queue_size} in queue"
    puts "Runtime: #{stats.time.round(2)} seconds"
  end

  # Detailed report every 30 seconds
  timer(30) do |stats|
    puts "\n=== Pipeline Status Report ==="
    puts "Completed: #{stats.completed}"
    puts "Queue size: #{stats.queue_size}"
    puts "Runtime: #{stats.time.round(2)}s"
    puts "============================\n"
  end

  process(store.user.where(processed: false)) do |user|
    expensive_operation(user)
    user.update!(processed: true)
  end
end

pipeline.process(store)
```

**Timer receives a Stats object with:**
- `stats.queue_size` - Number of items currently in the queue waiting to be processed
- `stats.completed` - Total number of steps that have been completed
- `stats.time` - Number of seconds the pipeline has been running (as a Float)

**Timer behavior:**
- Timers run on separate threads/fibers and don't block processing
- Timer errors are silently caught to prevent pipeline interruption
- Timers automatically stop when the pipeline completes
- Works with both `:sync` and `:async` processors

### Recovering from Failures

The store automatically versions your data. If processing fails, fix your code and restore from where you left off:

```ruby
# First run - fails partway through
store = ConcurrentPipeline.store do
  dir("/tmp/my_pipeline")

  record(:user) do
    schema(:users) do |t|
      t.string(:name)
      t.string(:email)
      t.boolean(:email_sent, default: false)
    end
  end
end
end

store.transaction do
  5.times { |i| store.user.create!(name: "User#{i}") }
end

pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(store.user.where(email_sent: false)) do |user|
    # Oops, forgot to handle missing emails
    email = fetch_email_for(user.name)  # Might return nil!
    send_email(email)  # This will fail if email is nil
    user.update!(email: email, email_sent: true)
  end
end

pipeline.process(store)  # Some succeed, some fail

# Check what versions exist
store.versions.each_with_index do |version, i|
  puts "Version #{i}: #{version.user.where(email_sent: true).count} emails sent"
end

# Restore from a previous version
store.restore_version(store.versions[1])

# Now run with fixed logic
pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  process(store.user.where(email_sent: false)) do |user|
    email = fetch_email_for(user.name) || "default@example.com"  # Fixed!
    send_email(email)
    user.update!(email: email, email_sent: true)
  end
end

pipeline.process(store)  # Only processes remaining users
```

### Storage Structure

The store uses SQLite databases for storage:

```
/tmp/my_pipeline/
├── db.sqlite3   # Current state database
└── versions/
    ├── {timestamp}.sqlite3  # Historical version backups
```

- **`db.sqlite3`**: Contains the current state of your data with full ActiveRecord capabilities.
- **`versions/`**: Contains complete database snapshots taken at each version point.

Versions are automatically created during pipeline processing, allowing you to inspect historical states and restore if needed. Each version is a complete, independent SQLite database.

### Running Shell Commands

The `Shell` class helps run external commands within your pipeline. It exists because running shell commands in Ruby can be tedious - you need to capture stdout, stderr, check exit status, and handle failures. Shell simplifies this.

Available in process blocks via the `shell` helper:

```ruby
pipeline = ConcurrentPipeline.pipeline do
  processor(:sync)

  process(store.repository.where(cloned: false)) do |repo|
    # Shell.run returns a Result with stdout, stderr, success?, command
    result = shell.run("git clone #{repo.url} /tmp/#{repo.name}")

    if result.success?
      puts result.stdout
      repo.update!(cloned: true)
    else
      puts "Failed: #{result.stderr}"
    end
  end
end
```

Use `run!` to raise on failure:

```ruby
process(store.repository.where(cloned: false)) do |repo|
  # Raises error if command fails, returns stdout if success
  output = shell.run!("git clone #{repo.url} /tmp/#{repo.name}")
  repo.update!(cloned: true, output: output)
end
```

Stream output in real-time with a block:

```ruby
process(store.project.where(built: false)) do |project|
  shell.run("npm run build") do |stream, line|
    puts "[#{stream}] #{line}"
  end
  project.update!(built: true)
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
  dir("/tmp/my_pipeline")

  record(:company) do
    schema(:companies) do |t|
      t.string(:name)
      t.boolean(:fetched, default: false)
    end
  end

  record(:employee) do
    schema(:employees) do |t|
      t.string(:company_name)
      t.string(:name)
      t.boolean(:processed, default: false)
    end
  end
end

store.transaction do
  store.company.create!(name: "Acme Corp")
  store.company.create!(name: "Tech Inc")
end

pipeline = ConcurrentPipeline.pipeline do
  processor(:async)

  # Step 1: Fetch employees for each company
  process(store.company.where(fetched: false)) do |company|
    employees = api_fetch_employees(company.name)
    employees.each do |emp|
      store.employee.create!(company_name: company.name, name: emp)
    end
    company.update!(fetched: true)
  end

  # Step 2: Process each employee
  process(store.employee.where(processed: false)) do |employee|
    send_welcome_email(employee.name)
    employee.update!(processed: true)
  end
end

pipeline.process(store)
```

### Final words

That's it, you've reached THE END OF THE INTERNET.
