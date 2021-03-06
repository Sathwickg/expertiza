class LotteryController < ApplicationController
  require 'json'
  require 'rest_client'

  # Give permission to run the bid to appropriate roles
  def action_allowed?
    ['Instructor',
     'Teaching Assistant',
     'Administrator'].include? current_role_name
  end


  # This method is to send request to web service and use k-means and students' bidding data to build teams automatically.
  def run_intelligent_assignment
    priority_info = []
    assignment = Assignment.find_by(id: params[:id])
    topics = assignment.sign_up_topics
    teams = assignment.teams
    puts 'assignment.type'
    puts assignment.type_id
    teams.each do |team|
      # grab student id and list of bids
      bids = []
      topics.each do |topic|
        bid_record = Bid.find_by(team_id: team.id, topic_id: topic.id)
        bids << (bid_record.nil? ? 0 : bid_record.priority ||= 0)
      end
      team.users.each { |user| priority_info << { pid: user.id, ranks: bids } if bids.uniq != [0] }
    end
    
    if !assignment.type_id
      begin
        data = { users: priority_info, max_team_size: assignment.max_team_size }
        url = WEBSERVICE_CONFIG["topic_bidding_webservice_url"]
        response = RestClient.post url, data.to_json, content_type: :json, accept: :json
        # store each summary in a hashmap and use the question as the key
        teams = JSON.parse(response)["teams"]
        create_new_teams_for_bidding_response(teams, assignment)
        run_intelligent_bid(assignment)
      rescue => err
        flash[:error] = err.message
      end

    else
      puts 'Running conference'
      run_conference_bid assignment, assignment.max_reviews_per_submission
    end

    redirect_to controller: 'tree_display', action: 'list'
  end
 def run_conference_bid  assignment, topic_per_team
    incomplete_teams = Hash.new(0)
    incomplete_topics = Hash.new(0)
    max_limit_of_topics = Hash.new(0)
    max_topics_for_assignment = 0
    teams = assignment.teams
    all_topics = assignment.sign_up_topics
    #looping through each topic to get the max limit of them and total topic count for the assignment
    all_topics.each do |topic|
      max_limit_of_topics.store(topic.id,topic.max_choosers)
      max_topics_for_assignment =max_topics_for_assignment + topic.max_choosers
    end

    score_list=Array.new(teams.length*all_topics.length){Array.new(3)}
    sorted_list=Array.new(teams.length*all_topics.length){Array.new(3)}
    temp=[]
    base = 10
    p = 0
    #looping through each team to calculate score for each topic in the assignment
    teams.each do |t|
      #intializing the hash with team id as key and 0 as default
      incomplete_teams.store(t.id,0)
      team_bids = Bid.where(team_id: t.id)
      denom = 0
      b_length = team_bids.length
      (1..b_length).each do |i|
        denom = denom+all_topics.length - i
      end
      #Score calculation based on bid priority
      all_topics.each do |j|
        if(team_bids.any?{|tb| tb.topic_id == j.id})
          bid_priority = Bid.where(team_id:t.id,topic_id:j.id).first.priority
          score = base+((all_topics.length+1-bid_priority)*base*all_topics.length) / denom
        elsif(team_bids.length!=0)
          score = base-(base*all_topics.length)/denom
        else
          score = base
        end
        score_list[p][0] = 1000/score
        score_list[p][1] = t.id
        score_list[p][2] = j.id
        p+=1
      end
    end
    #sorting the array based on the scores, team id and then topic ids
    sorted_list = score_list.sort_by{|e| [e[0],e[1],e[2]]}.each{|line| p line}
    #intializing the topics hash with topic id and 0 as default
    all_topics.each do |k|
      incomplete_topics.store(k.id,0)
    end

    #if there are more teams than the total topics avaialable in the assignment then we raise a warning message
    if(max_topics_for_assignment<teams.length)
      flash[:error] = 'There are not enough reviews to be assigned'
    end

    #Assigning topics to teams based on highest score
    sorted_list.each do |s|
      if((incomplete_topics[s[2]]<max_limit_of_topics[s[2]]) && (incomplete_teams[s[1]]<topic_per_team))
        puts max_limit_of_topics[s[2]]

        #making the assignment between the topic and team based on highest score
        SignedUpTeam.create(team_id: s[1], topic_id: s[2])
        #incrementing the counter for the team and topic who got the assignment
        incomplete_teams[s[1]]+=1

        incomplete_topics[s[2]]+=1

      end
    end
    #updating the assignment with is inteligent as false so that we should be able to run the assignment twice
    assignment.update_attribute(:is_intelligent,false)
    flash[:notice] = 'The intelligent assignment was successfully completed for ' + assignment.name + '.'
  end
  
  def create_new_teams_for_bidding_response(teams, assignment)
    original_team_ids = assignment.teams.map(&:id)
    teams.each do |user_ids|
      current_team, parent = nil, nil
      user_ids.each_with_index do |user_id, index|
        original_team_ids.each do |original_team_id|
          team_user = TeamsUser.find_by(user_id: user_id, team_id: original_team_id)
          next unless team_user
          if index.zero?
            # keep the original team of 1st user if exists and ask later students join in this team
            current_team = team_user.team
            parent = TeamNode.find_by(parent_id: assignment.id, node_object_id: current_team.id)
            break if current_team and parent
            current_team = AssignmentTeam.create(name: assignment.name + '_Team' + rand(10000).to_s, parent_id: assignment.id)
            parent = TeamNode.create(parent_id: assignment.id, node_object_id: current_team.id)
          end
          team_user.team_user_node.destroy
          team_user.destroy
          # transfer biddings from old team to new team
          Bid.where(team_id: original_team_id).update_all(team_id: current_team.id)
        end
        team_user = TeamsUser.find_by(user_id: user_id, team_id: current_team.id)
        unless team_user
          team_user = TeamsUser.create(user_id: user_id, team_id: current_team.id)
          TeamUserNode.create(parent_id: parent.id, node_object_id: team_user.id)
        end
      end
    end
    # remove empty teams
    assignment.teams.each do |team|
      if team.teams_users.empty?
        TeamNode.where(parent_id: assignment.id, node_object_id: team.id).destroy_all
        team.destroy
      end
    end
  end

  # This method is called for assignments which have their is_intelligent property set to 1. It runs a stable match algorithm and assigns topics
  # to strongest contenders (team strength, priority of bids)
  def run_intelligent_bid(assignment)
    unless assignment.is_intelligent # if the assignment is intelligent then redirect to the tree display list
      flash[:error] = "This action is not allowed. The assignment #{assignment.name} does not enable intelligent assignments."
      redirect_to controller: 'tree_display', action: 'list'
      return
    end
    # Getting signuptopics with max_choosers > 0
    sign_up_topics = SignUpTopic.where('assignment_id = ? and max_choosers > 0', params[:id])
    unassigned_teams = AssignmentTeam.where(parent_id: params[:id]).reject {|t| SignedUpTeam.where(team_id: t.id, is_waitlisted: 0).any? }
    unassigned_teams.sort! do |t1, t2|
      [TeamsUser.where(team_id: t2.id).size, Bid.where(team_id: t1.id).size] <=>
      [TeamsUser.where(team_id: t1.id).size, Bid.where(team_id: t2.id).size]
    end
    team_bids = []
    unassigned_teams.each do |team|
      topic_bids = []
      sign_up_topics.each do |topic|
        bid = Bid.find_by(team_id: team.id, topic_id: topic.id)
        topic_bids << { topic_id: topic.id, priority: bid.priority } if bid
      end
      topic_bids.sort! {|b| b[:priority] }
      team_bids << {team_id: team.id, bids: topic_bids}
    end

    team_bids.each do |tb|
      tb[:bids].each do |bid|
        num_of_signed_up_teams = SignedUpTeam.where(topic_id: bid[:topic_id]).count
        max_choosers = SignUpTopic.find_by(id: bid[:topic_id]).try(:max_choosers)
        if num_of_signed_up_teams < max_choosers
          SignedUpTeam.create(team_id: tb[:team_id], topic_id: bid[:topic_id])
          break
        end
      end
    end

    # auto_merge_teams unassignedTeams, finalTeamTopics

    # Remove is_intelligent property from assignment so that it can revert to the default signup state
    assignment = Assignment.find_by(id: params[:id])
    assignment.update_attribute(:is_intelligent, false)
    flash[:success] = 'The intelligent assignment was successfully completed for ' + assignment.name + '.'
  end

  # This method is called to automerge smaller teams to teams which were assigned topics through intelligent assignment
  def auto_merge_teams(unassigned_teams, _final_team_topics)
    assignment = Assignment.find(params[:id])
    # Sort unassigned
    unassigned_teams = Team.where(id: unassigned_teams).sort_by {|t| !t.users.size }
    unassigned_teams.each do |team|
      sorted_bids = Bid.where(user_id: team.id).sort_by(&:priority) # Get priority for each unassignmed team
      sorted_bids.each do |b|
        winning_team = SignedUpTeam.where(topic: b.topic_id).first.team_id
        next unless TeamsUser.where(team_id: winning_team).size + team.users.size <= assignment.max_team_size # If the team can be merged to a bigger team
        TeamsUser.where(team_id: team.id).update_all(team_id: winning_team)
        Bid.delete_all(user_id: team.id)
        Team.delete(team.id)
        break
      end
    end
  end
end
