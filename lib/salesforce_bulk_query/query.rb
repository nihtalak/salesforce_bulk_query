require 'salesforce_bulk_query/job'

module SalesforceBulkQuery

  # Abstraction of a single user-given query. It contains multiple jobs, is tied to a specific connection
  class Query

    # if no created_to is given we use the current time with this offset
    # subtracted (to make sure the freshest changes that can be inconsistent
    # aren't there) It's in minutes
    OFFSET_FROM_NOW = 10

    def initialize(sobject, soql, connection, options)
      @sobject = sobject
      @soql = soql
      @connection = connection
      @logger = options[:logger]
      @created_from = options[:created_from]
      @created_to = options[:created_to]
      @single_batch = options[:single_batch]
      @jobs_in_progress = []
      @jobs_done = []
      @finished_batch_filenames = []
      @restarted_subqueries = []
    end

    DEFAULT_MIN_CREATED = "1999-01-01T00:00:00.000Z"

    # Creates the first job, divides the query to subqueries, puts all the subqueries as batches to the job
    def start
      # order by and where not allowed
      if (!@single_batch) && (@soql =~ /WHERE/i || @soql =~ /ORDER BY/i)
        raise "You can't have WHERE or ORDER BY in your soql. If you want to download just specific date range use created_from / created_to"
      end

      # create the first job
      job = SalesforceBulkQuery::Job.new(@sobject, @connection, @logger)
      job.create_job

      # get the date when it should start
      if @created_from
        min_created = @created_from
      else
        # get the date when the first was created
        min_created = nil
        begin
          min_created_resp = @connection.client.query("SELECT CreatedDate FROM #{@sobject} ORDER BY CreatedDate LIMIT 1")
          min_created_resp.each {|s| min_created = s[:CreatedDate]}
        rescue Faraday::Error::TimeoutError => e
          @logger.warn "Timeout getting the oldest object for #{@sobject}. Error: #{e}. Using the default value" if @logger
          min_created = DEFAULT_MIN_CREATED
        end
      end

      # generate intervals
      start = DateTime.parse(min_created)
      stop = @created_to ? DateTime.parse(@created_to) : DateTime.now - Rational(OFFSET_FROM_NOW, 1440)
      job.generate_batches(@soql, start, stop, @single_batch)

      job.close_job

      @jobs_in_progress.push(job)
    end


    # Check statuses of all jobs
    def check_status
      all_done = true
      job_statuses = []
      # check all jobs statuses and put them in an array
      @jobs_in_progress.each do |job|
        job_status = job.check_status
        all_done &&= job_status[:finished]
        job_statuses.push(job_status)
      end

      return {
        :finished => all_done,
        :job_statuses => job_statuses
      }
    end

    # Get results for all jobs
    # @param options[:directory_path]
    def get_results(options)
      all_job_results = []
      job_result_filenames = []
      unfinished_subqueries = []
      # check each job and put it there
      @jobs_in_progress.each do |job|
        job_results = job.get_results(options)
        all_job_results.push(job_results)
        job_result_filenames += job_results[:filenames]
        unfinished_subqueries.push(job_results[:unfinished_batches].map {|b| b.soql})
      end
      return {
        :filenames => job_result_filenames + @finished_batch_filenames,
        :unfinished_subqueries => unfinished_subqueries,
        :restarted_subqueries => @restarted_subqueries,
        :results => all_job_results,
        :done_jobs => @jobs_done
      }
    end

    # Restart unfinished batches in all jobs in progress, creating new jobs
    # downloads results for finished batches
    def get_result_or_restart(options)
      new_jobs = []
      job_ids_to_remove = []
      jobs_done = []

      @jobs_in_progress.each do |job|
        # get available stuff, if not the right time yet, go on
        available_results = job.get_available_results(options)
        if available_results.nil?
          next
        end

        unfinished_batches = available_results[:unfinished_batches]

        # store the filenames and resturted stuff
        @finished_batch_filenames += available_results[:filenames]
        @restarted_subqueries += unfinished_batches.map {|b| b.soql}

        unfinished_batches.each do |batch|
          # for each unfinished batch create a new job and add it to new jobs
          @logger.info "The following subquery didn't end in time: #{batch.soql}. Dividing into multiple and running again" if @logger
          new_job = SalesforceBulkQuery::Job.new(@sobject, @connection)
          new_job.create_job
          new_job.generate_batches(@soql, batch.start, batch.stop)
          new_job.close_job
          new_jobs.push(new_job)
        end
        # the current job to be removed from jobs in progress
        job_ids_to_remove.push(job.job_id)
        jobs_done.push(job)
      end
      # remove the finished jobs from progress and add there the new ones
      @jobs_in_progress.select! {|j| ! job_ids_to_remove.include?(j.job_id)}
      @jobs_done += jobs_done

      @jobs_in_progress += new_jobs
    end
  end
end