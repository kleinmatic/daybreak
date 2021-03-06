module Daybreak
  # Writer's handle the actually fiddly task of committing data to disk.
  # They have a Worker instance that writes in a select loop.
  class Writer
    # Open up the file, ready it for binary and nonblocking writing.
    def initialize(file)
      @file = file
      open!
      @worker = Worker.new(@fd)
    end

    # Send a record to the workers queue.
    def write(record)
      @worker.enqueue record
    end

    # Finish writing
    def finish!
      @worker.finish!
    end

    # Flush pending commits, and restart the worker.
    def flush!
      @worker.flush!
    end

    # Finish writing and close the file descriptor.
    def close!
      finish!
      @fd.close
    end

    # Truncate the file.
    def truncate!
      finish!
      @fd.truncate(0)
      @fd.pos = 0
    end

    private

    def open!
      @fd = File.open @file, 'ab'

      if defined?(Fcntl::O_NONBLOCK)
        f = @fd.fcntl(Fcntl::F_GETFL, 0)
        @fd.fcntl(Fcntl::F_SETFL, Fcntl::O_NONBLOCK | f)
      end
    end

    # Workers handle the actual fiddly bits of asynchronous io and
    # and handle background writes.
    class Worker
      def initialize(fd)
        @queue  = Queue.new
        @fd     = fd
        @thread = Thread.new { work }
        at_exit { finish! }
      end

      # Queue up a write to be committed later.
      def enqueue(record)
        @queue << record
      end

      # Loop and block if we don't have work to do or if
      # the file isn't ready for another write just yet.
      def work
        buf, finished = '', false
        until finished && buf.empty?
          record = @queue.pop
          if record
            buf << Record.serialize(record)
          else
            finished = true
          end
          read, write = IO.select [], [@fd]
          if write and fd = write.first
            lock(fd) { buf = try_write fd, buf }
          end
        end
        @fd.flush
      end

      # Try and write the buffer to the file via non blocking file writes.
      # If the write fails try again.
      def try_write(fd, buf)
        if defined?(Fcntl::O_NONBLOCK)
          s = fd.write_nonblock(buf)
        else
          s = fd.write(buf)
        end
        if s < buf.length
          buf = buf[s..-1] # didn't finish
        else
          buf = ""
        end
        buf
      rescue Errno::EAGAIN
        buf
      end

      # Lock a file with the type <tt>lock</tt>
      def lock(fd)
        fd.flock File::LOCK_EX
        begin
          yield
        ensure
          fd.flock File::LOCK_UN
        end
      end

      # finish! and start up another worker thread.
      def flush!
        finish!
        @thread = Thread.new { work }
        true
      end

      # Push a nil through the queue and block until the write loop is finished.
      def finish!
        @queue.push nil
        @thread.join
      end
    end
  end
end
