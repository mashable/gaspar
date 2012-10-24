require 'spec_helper'

describe Gaspar do
  let(:redis) { Redis.new }
  after(:each) { Gaspar.destruct! }
  context "when running in a non-daemon" do
    it "should refuse to start if under a controlling TTY" do
      STDOUT.stub(:tty?).and_return(true)
      Gaspar.should_receive(:log).with(nil, "Running under a controlling TTY. Refusing to start. Try starting from a daemonized process.")
      Gaspar.configure do
        every "5m", :Foo
      end.start!(redis)
    end
  end

  context "when running in a daemon" do
    before(:each) {
      STDOUT.stub(:tty?).and_return(false)
      STDERR.stub(:tty?).and_return(false)
    }

    context "configuration" do
      it "should accept #every during configuration" do
        Gaspar.any_instance.should_receive(:schedule).with(:every, "5m", [], instance_of(Hash))
        Gaspar.configure do
          every("5m") { puts "Doing stuff" }
        end.start!(redis)
      end

      it "should require a name if a block is passed to a job" do
        expect {
          Gaspar.configure do
            every("5m") { puts "Doing stuff" }
          end.start!(redis)
        }.to raise_error("No :name specified and sourcify is not available. Specify a name, or add sourcify to your bundle.")
      end

      it "should not require a name if a symbol is passed to a job" do
        expect {
          Gaspar.configure do
            every "5m", :Foobar
          end.start!(redis)
        }.to_not raise_error
      end

      it "should enqueue a job" do
        Time.stub!(:now).and_return Time.at(1351061802)
        Gaspar.any_instance.stub(:drift).and_return(0)
        Gaspar.configure do
          every "5m", :Foobar
        end
        scheduler = double(:scheduler)
        Gaspar.singleton.stub(:scheduler).and_return scheduler
        scheduler.should_receive(:every).with("5m", :first_at => Time.at(1351062000))
        Gaspar.start!(redis)
      end

      it "should accept #cron during configuration" do
        Gaspar.any_instance.should_receive(:schedule).with(:cron, "* * * * *", [], instance_of(Hash))
        Gaspar.configure do
          cron("* * * * *") { puts "Doing stuff" }
        end.start!(redis)
      end

      it "should quantitize #every to the next timeslice" do
        Time.stub!(:now).and_return Time.at(1351061802)
        Gaspar.any_instance.stub(:drift).and_return(0)
        Gaspar.any_instance.should_receive(:schedule).with(:every, "5m", [], {:first_at => Time.at(1351062000), :period => 300.0})
        Gaspar.configure do
          every("5m") { puts "Doing stuff" }
        end.start!(redis)
      end

      it "should detect Resque" do
        Resque = 1
        Gaspar.configure do
          every "5m", :Foo
        end.start!(redis)
        Gaspar.singleton.instance_variable_get("@options")[:worker].should == :resque
        Object.send :remove_const, :Resque
      end

      it "should detect Sidekiq" do
        Sidekiq = 1
        Gaspar.configure do
          every "5m", :Foo
        end.start!(redis)
        Gaspar.singleton.instance_variable_get("@options")[:worker].should == :sidekiq
        Object.send :remove_const, :Sidekiq
      end

      it "should process jobs" do
        value = 0
        sleep 0.4
        Gaspar.configure do
          every "0.35s", "update variable" do
            value += 1
          end
        end.start!(redis)
        value.should == 0
        sleep(0.4)
        value.should > 0
      end

      it "should prevent jobs from running multiple times for the same time period" do
        value = 0
        sleep 0.4
        Gaspar.configure do
          every("0.35s", "update variable with lock") { value += 1 }
          every("0.35s", "update variable with lock") { value += 1 }
          every("0.35s", "update variable with lock") { value += 1 }
        end.start!(redis)
        value.should == 0
        sleep(0.4)
        value.should == 1
      end

    end

    context "class methods" do
      describe "#log" do
        it "should silently eat logging messages when no logger is specified" do
          expect { Gaspar.log(nil, "foobar") }.to_not raise_error
        end
      end

      describe "#log" do
        it "should log when a logger is passed" do
          logger = double(:logger, :debug => true)
          expect { Gaspar.log(logger, "foobar") }.to_not raise_error
        end
      end

      describe "#destruct!" do
        it "should not fail when the singleton has not been initialized" do
          expect { Gaspar.destruct! }.to_not raise_error
        end

        it "should kill the singleton if it has been previous initialized" do
          Gaspar.configure do
            every("5m") { puts "Doing stuff" }
          end
          Gaspar.singleton.should_receive(:shutdown!)
          Gaspar.destruct!
        end
      end

      describe "#start!" do
        it "should fail if the singleton has not been initialized" do
          expect { Gaspar.start!(redis) }.to raise_error "Gaspar#configure has not been called, or did not succeed"
        end

        it "succeeds if the singleton has been initialized" do
          Gaspar.configure do
            every("5m", :name => "do stuff") { puts "Doing stuff" }
          end.start!(redis)
          Gaspar.singleton.instance_variable_get("@started").should == true
        end
      end
    end

    context "instance methods" do
      describe "#sync_watches" do
        it "should compute drift" do
          Time.stub!(:now).and_return(150)
          redis = double :redis, :setnx => false, :get => "100", :ttl => (3.2e8.to_i - 25)
          instance = Gaspar.send(:new)
          instance.instance_variable_set(:@redis, redis) 
          instance.send :sync_watches
          instance.drift.should == 25
        end
      end
    end
  end
end
