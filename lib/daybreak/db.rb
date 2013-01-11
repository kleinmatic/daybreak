module Daybreak
  # Daybreak::DB contains the public api for Daybreak. It includes
  # Enumerable for functional goodies like map, each, reduce and friends.
  class DB
    include Enumerable

    attr_reader :file, :logsize
    attr_accessor :default

    def self.databases
      at_exit do
        until @databases.empty?
          warn "Database #{@databases.first.file} was not closed, state might be inconsistent"
          @databases.first.close
        end
      end unless @databases
      @databases ||= []
    end

    # Create a new Daybreak::DB. The second argument is the default value
    # to store when accessing a previously unset key, this follows the
    # Hash standard.
    # @param [String] file the path to the db file
    # @param default the default value to store and return when a key is
    #  not yet in the database.
    # @yield [key] a block that will return the default value to store.
    # @yieldparam [String] key the key to be stored.
    def initialize(file, options = {}, &block)
      @file = file
      @serializer = (options[:serializer] || Serializer::Default).new
      @format = (options[:format] || Format).new(@serializer)
      @default = block ? block : options[:default]
      @queue = []
      @mutex = Mutex.new
      @full = ConditionVariable.new
      @empty = ConditionVariable.new
      @out = File.open(@file, 'ab')
      if @out.stat.size == 0
        @out.write(@format.header)
        @out.flush
      end
      reset
      @thread = Thread.new(&method(:worker))
      sync
      self.class.databases << self
    end

    # Retrieve a value at key from the database. If the default value was specified
    # when this database was created, that value will be set and returned. Aliased
    # as <tt>get</tt>.
    # @param key the value to retrieve from the database.
    def [](key)
      skey = @serializer.key_for(key)
      if @table.has_key?(skey)
        @table[skey]
      elsif @default
        set(key, @default.respond_to?(:call) ? @default.call(key) : @default)
      end
    end
    alias_method :get, :'[]'

    # Set a key in the database to be written at some future date. If the data
    # needs to be persisted immediately, call <tt>db.set(key, value, true)</tt>.
    # @param [#to_s] key the key of the storage slot in the database
    # @param value the value to store
    def []=(key, value)
      key = @serializer.key_for(key)
      write([key, value])
      @table[key] = value
    end
    alias_method :set, :'[]='

    # set! flushes data immediately to disk.
    # @param key the key of the storage slot in the database
    # @param value the value to store
    def set!(key, value)
      set(key, value)
      @mutex.synchronize { flush }
      value
    end

    # Delete a key from the database
    # @param key the key of the storage slot in the database
    def delete(key)
      key = @serializer.key_for(key)
      write([key])
      @table.delete(key)
    end

    # delete! immediately deletes the key on disk.
    # @param key the key of the storage slot in the database
    def delete!(key)
      value = delete(key)
      @mutex.synchronize { flush }
      value
    end

    # Does this db have a value for this key?
    # @param key the key to check if the DB has a key.
    def has_key?(key)
      @table.has_key?(@serializer.key_for(key))
    end

    # Return the number of stored items.
    # @return [Integer]
    def size
      @table.size
    end
    alias_method :length, :size

    # Iterate over the key, value pairs in the database.
    # @yield [key, value] blk the iterator for each key value pair.
    # @yieldparam key the key.
    # @yieldparam value the value from the database.
    def each(&block)
      @table.each(&block)
    end

    # Return the keys in the db.
    # @return [Array]
    def keys
      @table.keys
    end

    # Sync the database with what is on disk, by first flushing changes, and
    # then reading the file if necessary.
    def sync
      @mutex.synchronize do
        flush
        update
      end
    end

    # Lock the database for an exclusive commit accross processes and threads
    # @yield a block where every change to the database is synced
    def lock
      @mutex.synchronize do
        exclusive do
          flush
          update
          result = yield
          flush
          result
        end
      end
    end

    # Remove all keys and values from the database
    def clear
      with_tmpfile do |path, file|
        file.close
        exclusive do
          flush
          # Clear acts like a compactification
          File.rename(path, @file)
        end
        @in.close
        reset
      end
      self
    end

    # Compact the database to remove stale commits and reduce the file size.
    def compact
      with_tmpfile do |path, file|
        compactsize = file.write(dump)
        exclusive do
          newsize = @in.stat.size
          # Is the new database different?
          return if newsize == compactsize
          # Check if database changed in the meantime
          if newsize > @in.pos
            # Append changed journal records
            file.write(@in.read(newsize - @in.pos))
          end
          file.close
          File.rename(path, @file)
        end
        update
      end
      self
    end

    # Close the database for reading and writing.
    def close
      write(nil)
      @thread.join
      @in.close
      @out.close
      self.class.databases.delete(self)
      nil
    end

    private

    def update
      buf = new_records
      until buf.empty?
        record = @format.deserialize(buf)
        if record.size == 1
          @table.delete(record.first)
        else
          @table[record.first] = record.last
        end
        @logsize += 1
      end
    end

    def new_records
      stat = nil
      loop do
        @in.flock(File::LOCK_SH) unless @exclusive
        stat = @in.stat
        # Check if database was compactified in the meantime
        # break if not
        break if stat.nlink > 0
        @in.close
        reset
      end

      # Read new journal records
      if stat.size > @in.pos
        @in.read(stat.size - @in.pos)
      else
        ''
      end
    ensure
      @in.flock(File::LOCK_UN) unless @exclusive
    end

    def flush
      @empty.wait(@mutex) until @queue.empty?
    end

    def write(record)
      @queue << record
      @full.signal
    end

    def reset
      @logsize = 0
      @in = File.open(@file, 'rb')
      @format.read_header(@in)
      @table = {}
    end

    def dump
      @table.inject('') do |dump, record|
        dump << @format.serialize(record)
      end
    end

    def worker
      @mutex.synchronize do
        loop do
          @full.wait(@mutex) while @queue.empty?
          record = @queue.first
          write_record(record) if record
          @queue.shift
          @empty.signal if @queue.empty?
          break unless record
        end
      end
    rescue Exception => ex
      warn "Daybreak worker: #{ex.message}"
      retry
    end

    def write_record(record)
      record = @format.serialize(record)
      exclusive do
        @out.write(record)
        # Flush to make sure the file is really updated
        @out.flush
        size = @out.stat.size
      end
      @in.pos = size if size == @in.pos + record.size
      @logsize += 1
    end

    def exclusive
      loop do
        @out.flock(File::LOCK_EX)
        # Check if database was compactified in the meantime
        # break if not
        break if @out.stat.nlink > 0
        @out.close
        @out = File.open(@file, 'ab')
      end
      @exclusive = true
      yield
    ensure
      @out.flock(File::LOCK_UN)
      @exclusive = false
    end

    def with_tmpfile
      path = [@file, $$.to_s(36), Thread.current.object_id.to_s(36)].join
      file = File.open(path, 'wb')
      file.write(@format.header)
      @mutex.synchronize { yield(path, file) }
    ensure
      file.close unless file.closed?
      File.unlink(path) if File.exists?(path)
    end
  end
end
