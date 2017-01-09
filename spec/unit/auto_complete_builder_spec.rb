require "spec_helper"

describe ScopedSearch::AutoCompleteBuilder do

  let(:klass) { @definition.stub(:klass).and_return(Class.new(ActiveRecord::Base)) }

  before(:each) do
    @definition = double('ScopedSearch::Definition')
    @definition.stub(:klass).and_return(klass)
    @definition.stub(:profile).and_return(:default)
    @definition.stub(:profile=).and_return(true)
  end

  it "should return empty suggestions if the search query is nil" do
    ScopedSearch::AutoCompleteBuilder.auto_complete(@definition, klass, nil).should == []
  end

  it "should return empty suggestions if the query is blank" do
    ScopedSearch::AutoCompleteBuilder.auto_complete(@definition, klass, "").should == []
  end

end
