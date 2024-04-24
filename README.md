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

WTFPL - website down but you can find it if you care

## Guide and Code Examples

### Simplest Usage

Define a producer and add a pipeline to it.

```ruby
# Define your producer:

class MyProducer < ConcurrentPipeline::Producer
  pipeline do
    steps(:step_1, :step_2)

    def step_1
      puts "hi from step_1"
    end

    def step_2
      puts "hi from step_2"
    end
  end
end

# Run your producer
producer = MyProducer.new
producer.call
# hi from step_1
# hi from step_2
```

Wow! What a convoluted way to just run two methods!

### Example of Processing data

The previous example just wrote to stdout. In general, we want to be storing all data in a dataset that we can review and potentially write to disk.

Pipelines provide three methods for you to use: (I should really figure out ruby-doc and link there :| )

- `Pipeline#store`: returns a Store
- `Pipeline#changeset`: returns a Changeset
- `Pipeline#stream`: returns a Stream (covered in a later example)

Here, we define a model and provide the producer some initial data. Models are stored in the `store`. The models themselves are immutable. In order to create or update a model, we must use the `changeset`.

```ruby
# Define your producer:

class MyProducer < ConcurrentPipeline::Producer
  model(:my_model) do
    attribute :id # an :id attribute is always required!
    attribute :status

    # You can add more methods here, but remember
    # models are immutable. If you update an
    # attribute here it will be forgotten at the
    # end of the step. All models are re-created
    # from the store for every step.

    def updated?
      status == "updated"
    end
  end

  pipeline do
    steps(:step_1, :step_2)

    def step_1
      # An :id will automatically be created or you can
      # pass your own:
      changeset.create(:my_model, id: 1, status: "created")
    end

    def step_2
      # You can find the model in the store:
      record = store.find(:my_model, 1)

      # or get them all and find it yourself if you prefer
      record = store.all(:my_model).select { |r| r.id == 1 }

      changeset.update(record, status: "updated")
    end
  end
end

producer = MyProducer.new

# invoke it:
producer.call

# view results:
puts producer.data
# {
#   my_model: [
#     { id: 1, status: "updated" },
#   ]
# }
```

Future examples show how to pass your initial data to a producer.

### Example with Concurrency

There are a few ways to declare what things should be done concurrently:

- Put steps in an array to indicate they can run concurrently
- Add two pipelines
- Pass the `each: {model_type}` option to the Pipeline indicating that it should be run for every record of that type.

The following example contains all three.

```ruby
class MyProducer < ConcurrentPipeline::Producer
  model(:my_model) do
    attribute :id # an :id attribute is always required!
    attribute :status
  end

  pipeline do
    # Steps :step_2 and :step_3 will be run concurrently.
    # Step :step_4 will only be run when they have both
    # finished successfully
    steps(
      :step_1,
      [:step_2, :step_3],
      :step_4
    )

    # noops since we're just demonstrating usage here.
    def step_1; end
    def step_2; end
    def step_3; end
    def step_4; end
  end

  # this pipeline will run concurrently with the prior
  # pipeline.
  pipeline do
    steps(:step_1)
    def step_1; end
  end

  # passing `each:` to the Pipeline indicates that it
  # should be run for every record of that type. When
  # `each:` is specified, the record can be accessed
  # using the `record` method.
  #
  # Note: every record will be processed concurrently.
  # You can limit concurrency by passing the
  # `concurrency: {integer}` option. The default
  # concurrency is Infinite! INFINIIIIITE!!1!11!!!1!
  pipeline(each: :my_model, concurrency: 3) do
    steps(:process)

    def process
      changeset.update(record, status: "processed")
    end
  end
end

# Lets Pass some initial data:
initial_data = {
  my_model: [
    { id: 1, status: "waiting" },
    { id: 2, status: "waiting" },
    { id: 3, status: "waiting" },
  ]
}
producer = MyProducer.new(data: initial_data)

# invoke it:
producer.call

# view results:
puts producer.data
# {
#   my_model: [
#     { id: 1, status: "processed" },
#     { id: 2, status: "processed" },
#     { id: 3, status: "processed" },
#   ]
# }
```

### Viewing history and recovering versions

A version is created each time a record is updated. This example shows how to view and rerun with a prior version.

It's important to note that the system tracks which steps have been performed and which are still waiting to run by writing records to the store. If you change the structure of your Producer (add/remove pipelines or add/remove steps from a pipeline), then there's no guarantee that your data will be compatible across that change. If, however, you only change the body of a step method, then you should be able to rerun a prior version without issue.

```ruby
class MyProducer < ConcurrentPipeline::Producer
  model(:my_model) do
    attribute :id # an :id attribute is always required!
    attribute :status
  end

  pipeline(each: :my_model) do
    steps(:process)

    def process
      changeset.update(record, status: "processed")
    end
  end
end

initial_data = {
  my_model: [
    { id: 1, status: "waiting" },
    { id: 2, status: "waiting" },
  ]
}
producer = MyProducer.new(data: initial_data)
producer.call

# access the versions like so:
puts producer.history.versions.count
# 5

# A version can tell you what diff it applied.
# Notice here, the :PipelineStep record, that
# is how the progress is tracked internally.
puts producer.history.versions[3].diff
# {
#   changes: [
#     {
#       :action: :update,
#       id: 1,
#       type: :my_model,
#       delta: {:status: "processed"}
#     },
#     {
#       action: :update,
#       id: "5d02ca83-0435-49b5-a812-d4da4eef080e",
#       type: :PipelineStep,
#       delta: {
#         :completed_at: "2024-05-10T18:44:04+00:00",
#         result: :success
#       }
#     }
#   ]
# }

# Let's re-process using a previous version:
# This will just pick up where it was left off
re_producer = MyProducer.new(
  store: producer.history.versions[3].store
)
re_producer.call

# If you need to change the code, you'd probably
# want to write the data to disk and then read
# it the next time you run:

File.write(
  "last_good_version.yml",
  producer.history.versions[3].store.data.to_yaml
)

# And then next time, load it like so:
re_producer = MyProducer.new(
  data: YAML.unsafe_load_file("last_good_version.yml")
)
```

### Monitoring progress

When you run a long-running script it's nice to know that it's doing something (anything!). Staring at an unscrolling terminal might be good news, might be bad news, might be no news. How to know?

Models are immutable and changesets are only applied after a step is completed. If you want to get some data out during processing, you can just `puts` it. Or if you'd like to be a bit more specific about what you track, you can push data to a centralized "stream".

Here's an example:

```ruby
class MyProducer < ConcurrentPipeline::Producer
  stream do
    on(:start) do |message|
      puts "Started processing #{message}"
    end

    on(:progress) do |data|
      puts "slept #{data[:slept]} times!"

      # you don't have to just "puts" here:
      # Audio.play(:jeopardy_music)
    end

    on(:finished) do
      Net::Http.get("http://zombo.com")
    end
  end

  pipeline do
    steps(:process)

    def process
      # the `push` method takes exactly two arguments:
      # type: A symbol
      # payload: any object, go crazy...
      # ...but remember...concurrency...
      stream.push(:start, "some_object!")
      sleep 1
      stream.push(:progress, {slept: 1 })
      sleep 1
      stream.push(:progress, { slept: 2 })
      changeset.update(record, status: "processed")

      # Don't feel pressured into sending an object
      # if you don't feel like it.
      stream.push(:finished)
    end
  end
end

some_other_object = [1, 2, 3]

producer = MyProducer.new
producer.call
puts some_other_object.inspect

# Started processing some_object!
# slept 1 times!
# slept 2 times!
# [3, 2, 1]
```

### Halting, Blocking, Triggering, etc

Perhaps you have a scenario where all ModelOnes have to be processed before any ModelTwo records. Or perhaps you want to find three ModelOne's that satisfy a certain condition and as soon as you've found those three, you want the pipeline to halt.

In order to allow this control, each pipline can specify an `open` method indicating whether the pipeline should continue with start or stop and/or continue processing vs halt at the end of the next step.

A pipeline is always "closed" when all of its steps are complete, so pipelines cannot loop. If you want a Pipeline to loop, you'd have to have an `each: :model` pipeline that creates a new model to be processed. The pipeline would then re-run (with the new model).

Here's an example with some custom "open" methods:

```ruby
class MyProducer < ConcurrentPipeline::Producer
  model(:model_one) do
    attribute :id # an :id attribute is always required!
    attribute :valid
  end

  model(:model_two) do
    attribute :id # an :id attribute is always required!
    attribute :processed
  end

  pipeline(each: :model_one) do
    # we close this pipeline as soon as we've found at least
    # three valid :model_one records. Note that because of
    # concurrency, we might not be able to stop at *exactly*
    # three valid models!
    open { store.all(:model_one).select(&:valid).count < 3 }

    steps(:process)

    def process
      sleep(rand(4))
      changeset.update(record, valid: true)
    end
  end

  pipeline(each: :model_two) do
    open { store.all(:model_one).select(&:valid).count >= 3 }

    # noop for example
    steps(:process)
    def process
      store.update(record, processed: true)
    end
  end

  pipeline do
    open {
      is_open = store.all(:model_two).all?(&:processed)
      stream.push(
        :stdout,
        "last pipeline is now: #{is_open ? :open : :closed}"
      )
      is_open
    }

    steps(:process)

    def process
      stream.push(:stdout, "all done")
    end
  end
end

initial_data = {
  model_one: [
    { id: 1, valid: false },
    { id: 2, valid: false },
    { id: 3, valid: false },
    { id: 4, valid: false },
    { id: 5, valid: false },
  ],
  model_two: [
    { id: 1, processed: false }
  ]
}
producer = MyProducer.new(data: initial_data)
producer.call
```

### Error Handling

What happens if a step raises an error? Theoretically, that particular pipeline should just halt and the error will be logged in the corresponding PipelineStep record.

The return value of `Pipeline#call` is a boolean indicating whether all PipelineSteps have succeeded.

It is possible that I've screwed this up and that an error leads to a deadlock. In order to prevent against data-loss, each update to the yaml file is written to disk in a directory you can find at `Pipeline#dir`. You can also pass your own directory during initialization: `MyPipeline.new(dir: "/tmp/my_dir")`

### Other hints

You can pass your data to a Producer in three ways:
- Passing a hash: `MyProducer.new(data: {...})`
- Passing a store: `MyProducer.new(store: store)`

Lastly, you can pass a block to apply changesets immediately:

```ruby
processor = MyProducer.new do |changeset|
  [:a, :b, :c].each do |item|
    changset.create(:model, name: item)
  end
end
```

If you need access to an outer scope for a stream to access, you can construct your own stream:

```ruby
# Streams are really about monitoring progress,
# so mutating state here is probably recipe for
# chaos and darkness, but hey, it's your code
# and I say fortune favors the bold (I've never
# actually said that until now).
my_stream = ConcurrentPipeline::Producer::Stream.new
outer_variable = :something
my_stream.on(:stdout) { outer_variable = :new_something }
MyProducer.new(stream: my_stream)
```

## Ruby can't do parallel processing so concurrency here is useless

Yes and no, but maybe, but maybe not. If you're waiting shelling out or waiting on a network request, then the concurrency will help you. If you're crunching numbers, then it will hurt you. If you're not familiar with ruby's GIL (GVL) then you can read a bit about it in this [separate doc](./concurrency.md) or you can search for it on AskJeeves (or your preferred internet search provider).
