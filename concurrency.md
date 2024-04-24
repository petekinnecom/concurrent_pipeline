## Ruby can't do parallel processing so concurrency here is useless

This is something that gets said every now and then. Also "concurrency is not parallelism" is often heard. Whether or not concurrency will help or hurt the performance of your script depends on what it does mostly.

tl;dr: Concurrency will hurt you if you're crunching lots of numbers. It will help you if you're shelling out or hitting the network. If you're really crunching so many numbers, maybe just use Go.

---

It's true, ruby (and javascript, python, etc..) do not allow you to have more than one line of code being executed on separate CPUs (or rather, cores) at the same time. So if you're writing a computationlly heavy script, given that ruby can only perform one computation at a time, concurrency will probably slow things down because it requires the VM to context switch between the various threads/fibers. This switching is costly in this scenario.

However, there's one slightly odd method that maybe doesn't work like you think: `sleep`. If I have a `sleep 1000` call in some method, when it hits that line when asked what the code is doing, most programmers would say "it's sleeping." But "sleeping" requires no CPU. In fact, sleeping requires the Ruby VM *not* to do a certain thing, which it can achieve by... doing something else! So, ruby *can* do two things at once: it can do something and it can also not do something at the same time! But wait? Is that parallelism or concurrency!? At the VM level, ruby is only executing one line of code, so it's concurrency. However... time is an independent variable that is always on the move. Conceptually, (IMO) the way programmers think about programs, `sleep` is effectively parallel.

Here's a slightly different way one might think about it: I have 14 cores on my computer. I probably have thousands of executables on my hard drive. Are those executables *not* running in parallel or concurrently?

What's actually happening under the hood? I don't **really** know, I'm not a ruby core contributor or anything. But here's some examples demonstrating how things work:

```ruby
# a mutex will ensure that the block is executed all in
# one go. No Thread switching allowed.
mutex = Mutex.new
proc = Proc.new  do
  mutex.synchronize do
    i = 0
    while(i < 200_000_000) do
      i+= 1
    end
  end
end

start = Time.now.to_f
[Thread.new(&proc), Thread.new(&proc)].map(&:join)
puts "with mutex: #{(Time.now.to_f - start)}"

# Here we call Thread.pass which tells the VM that now
# is a good time to switch Threads if it would like.
proc_2 = Proc.new  do
  i = 0
  while(i < 200_000_000) do
    i+= 1
    Thread.pass if i % 100_000 == 0
  end
end

start = Time.now.to_f
[Thread.new(&proc_2), Thread.new(&proc_2)].map(&:join)
puts "with pass: #{(Time.now.to_f - start)}"

# results:
# with mutex: 4.34
# with pass: 7.33
```

Notice the cost of switching threads! Now lets implement our own personal "sleep" method:

```ruby
mutex = Mutex.new
proc = Proc.new  do
  # here we sleep all in one go:
  mutex.synchronize do
    start_time = Time.now.to_f
    while(Time.now.to_f - start_time < 3); end
  end
end

start = Time.now.to_f
[Thread.new(&proc), Thread.new(&proc)].map(&:join)
puts "with mutex: #{(Time.now.to_f - start)}"

proc_2 = Proc.new  do
  start_time = Time.now.to_f

  # Use Thread.pass to indicate to the VM that
  # it can do something else if it likes.
  while(Time.now.to_f - start_time < 3)
    Thread.pass
  end
end

start = Time.now.to_f
[Thread.new(&proc_2), Thread.new(&proc_2)].map(&:join)
puts "with pass: #{(Time.now.to_f - start)}"

# results:
# with mutex: 6.00
# with pass: 3.00
```

Glorious. With our second implementation, we've made our own `sleep` functionality. And it's clear that two lines of code are never executing at the same time.

Oh well, whatever, concurrency, parallelism, etc. What matters is that if your code sleeps a lot, concurrency will improve performance. "But Pete", you ask, "why would I ever want to 'sleep' in a script!?" When you shell out to another process, ruby will sleep to wait for its results. When you hit the network, ruby will sleep to wait for its response. If you're doing that, then write a concurrent pipeline! If you're not, then don't bother. It turns out, we can all find joy and happiness together.
