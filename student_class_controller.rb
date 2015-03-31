require "json"

class Teacher::StudentClassController < Teacher::DefaultController

  include Build::TagHelper
  include Teacher::StudentClassHelper
  in_place_edit_for :student_class, :name
  in_place_edit_for :student_class, :grade
	helper FolderHelper
	include TeacherFolderHelper
	
	before_filter :initialize_instance_variables

  
  def index
    collect_grades
    @student_classes = current_user.teacher.student_classes.find(:all, :conditions => 'enabled = true')
	@disabled_classes = !current_user.teacher.student_classes.find(:first, :conditions => 'enabled = false').nil?
	
    sort_by_name!(@student_classes)
    @current_classes = true
	setup_folders  #Sets up the folders (TeacherFolderHelper
	@visited_comments = !comments_last_visited_time.nil?
    @num_of_new_comments = new_comments_since_last_visit
    get_all_settings
    render(:action => :list)
  end
  
  def disabled
    collect_grades
    @student_classes = current_user.teacher.student_classes.find(:all, :conditions => 'enabled = false')
    sort_by_name!(@student_classes)
    @current_classes = false
    get_all_settings
    render(:action => :list)
  end
  
  def roster
    return bounce('That class does not exist') if (@student_class = StudentClass.find_by_id(params[:id], :include => :student_class_sections)).nil?
    options = {:conditions => 'enabled = true'} if @student_class.enabled?
    return bounce('You do not teach that class') unless (@student_classes = current_user.teacher.student_classes.find(:all, options)).include?(@student_class)
    
    @student_class_sections = @student_class.student_class_sections
    sort_by_name!(@student_classes)
    sort_by_name!(@student_class_sections)
  end
  
  def assignments
    return bounce('That class does not exist') if (@student_class = StudentClass.find_by_id(params[:id], :include => [:students, :student_class_sections])).nil?

    ## redirect if folders is enabled
    redirect_to(:controller => :folder, :action => :index, :id => params[:id]) if @student_class.enable_folders?
    
    options = {:conditions => 'enabled = true'} if @student_class.enabled?
    return bounce('You do not teach that class') unless (@student_classes = current_user.teacher.student_classes.find(:all, options)).include?(@student_class)

    user_role_id = UserRole.find_by_user_id(current_user.id, :conditions => "role_id = #{Role::TEACHER}")[:id]
    @teacher_release_time = Setting.get_enabled_setting_value(user_role_id, "assignment_release_time", Scope::TEACHER) || []
    @teacher_due_time = Setting.get_enabled_setting_value(user_role_id, "assignment_due_time", Scope::TEACHER) || []


    # @my_assignments = @student_class.class_assignments
    # @my_assignments.delete_if{|i| !i.spiral_assignment_id.nil? }
    # filter relearning assignments
    @my_assignments = ClassAssignment.find(:all, :conditions => "student_class_id = #{@student_class.id} and spiral_assignment_id is null", :include => {:sequence => :base_section})
      assignment_id_list = @my_assignments.collect{|x| x.id}
    individual_assignment_list = @my_assignments.collect{|x| x.id if (x.curriculum_item_id == 1 or x.curriculum_item_id == 2)}.compact
      @student_class_id = @student_class.id
    if @my_assignments.size == 0
      @progresses = Hash.new
    else
      @progresses = @student_class.aggregate_progresses_new(assignment_id_list,individual_assignment_list)
    end
    sort_by_name!(@student_classes)
  end

  def show_assignable_assignments
    @taggable_ids = get_taggable_ids_from_params(params)
    sequences = @taggable_ids["Sequence"]
    @student_class = StudentClass.find(params[:student_class_id])
    if(params[:per_page].nil?)
      params[:per_page] ||= 10
    else
      params[:per_page] = params[:per_page].to_i
    end
    params[:page] ||= 1
    pp = params[:per_page]
    @class_assignments = @student_class.assigned_sequences
    # Paginates the sequences
    if((sequences == :all && Sequence.count > pp) || (sequences.size > pp))
      @sequence_pages, @sequences = paginate_model(:sequence, sequences, pp, params[:page], params[:conditions])
    else
      @sequences = Sequence.find(sequences, :conditions => params[:conditions])
    end
  end
  
  def create
    collect_grades
    @current_classes = true

    begin
      ActiveRecord::Base.transaction do
        creation_date = Time.now.strftime("(%b %d, %Y)") # e.g., (Jan 1st, 2000)
        params[:student_class][:name] = "#{params[:class_name]}" #Removed creation date from class name 7/1/14  CD
        if params["end_date"].nil?
          params["end_date"] = {"month" => Time.now.month.to_s,
                               "day"    => Time.now.day.to_s,
                               "year"   => (Time.now.year + 1).to_s}
        end
        if params["class_type_id"].nil?
          params["class_type_id"] = "1" # Anyone can enroll in this class
        end

        #The following has to be stored in the database. This solution is temporary.
        case  params[:student_class][:domain_id]
          when "1", "3", "6"
            params[:student_class][:domain_id] = "1"
          else
            params[:student_class][:domain_id] = "2"
        end

        @student_class = StudentClass.create(params[:student_class])
		

        # Set the end date.
        year  = params[:end_date][:year]
        month = params[:end_date][:month]
        day   = params[:end_date][:day]
        @student_class.update_attribute(:end_date, Time.utc(year, month, day))

        # Remove the default student class section and create the new ones.
        @student_class.student_class_sections.each {|student_class_section| student_class_section.destroy}
        params[:student_class_sections][:size].to_i.times do |index|
          @student_class.student_class_sections.create(:name => params[:student_class_sections][:name][index.to_s])
        end
				
		@student_class.student_class_sections.each do |section|
			unless section.valid?
				flash[:warning] = "Class not created: #{section.errors.full_messages.to_sentence}"
				@student_class = nil	
				raise ActiveRecord::ActiveRecordError
			end
		end
			
		unless @student_class.valid?
			flash[:warning] = "Class not created: #{@student_class.errors.full_messages.to_sentence}"
			@student_class = nil
			raise ActiveRecord::ActiveRecordError
		end
		
		if !params[:new_teacher].nil? and params[:new_teacher] == "true"
			current_user.teacher.set_default_class(@student_class.id)
		end
			
		
      end
    rescue Exception => exception
    	flash[:warning] = "Class not created: #{exception.message}"
      @student_class = nil
    end
    respond_to do |format|
      format.html {redirect_to(:controller => :folder, :action => :index, :id => @student_class.id)}
      format.js
    end
  end
  
  def enable 
    @student_class = StudentClass.find(params[:id])
    @student_class.update_attribute(:enabled, true)
    @student_class.update_attribute(:end_date, DateTime.now+365)
  end
  
  def disable 
    @student_class = StudentClass.find(params[:id])
    @student_class.update_attribute(:enabled, false)
    @student_class.update_attribute(:end_date, DateTime.now)
  end
  
  def reset_password
    @student = Student.find(params[:student_id], :include => :user)
    user = @student.user
    user.password = params[:student][:password]
    user.password_confirmation = params[:student][:password_confirmation]
    user.save
    @err = user.errors.full_messages.inject('') {|errors, error| errors << "* #{error}.\n"}
    @msg = user.errors.empty? ? 'Password successfully changed' : "Password was not changed because:\n#{@err}"
    respond_to do |format|
      format.js
    end
  end
  
  def change_section
	# Update attributes
	if Enrollment.exists?(params[:enrollment_id])
		@enrollment = Enrollment.find(params[:enrollment_id])
		@old_section = @enrollment.student_class_section
		@enrollment.update_attributes!(:student_class_section_id => params[:new_section])
		@enrollment.reload
		@new_section = @enrollment.student_class_section
		@student_class = StudentClassSection.find(@enrollment.student_class_section_id).student_class
		# Necessary for updating the page
		#@roster_entry = Enrollment.get_roster_entry_for_enrollment(params[:enrollment_id]).first
		@student_roster = Hash.new
		@student_roster[@new_section.id] = Enrollment.get_class_roster_with_student_bool @student_class.id, @new_section.id
		@student_roster[@old_section.id] = Enrollment.get_class_roster_with_student_bool @student_class.id, @old_section.id
		@parent_notification_enabled = @student_class.enable_parent_notification?
		setup_parents()
	end
  end
  
 

 def change_end_date
    @student_class = StudentClass.find_by_id(params[:student_class_id])
    year = params[:end_date][:year]
    month = params[:end_date][:month]
    day = params[:end_date][:day]
    @student_class.update_attribute(:end_date, Time.utc(year, month, day))
    flash[:notice] = "Class end date set"
  end

  def change_class_name
   
    @student_class = StudentClass.find_by_id(params[:student_class_id])
    new_name = params[:student_class][:name]
    @student_class.update_attribute(:name, new_name)
    flash[:notice] = "Class name changed."
  end

  def change_class_type
    class_enroll_type = ClassType.find_by_description(params[:student_class][:class_type_description])
    @student_class = StudentClass.find_by_id(params[:student_class_id])
    enroll_enabled = class_enroll_type == "Must wait for teacher approval" ? true : false
    Setting.create_or_update(@student_class.id, 'class_enroll_require_approval',  Scope::CLASS, true,enroll_enabled)
    flash[:notice] = "Class type changed."
  end

  def change_class_grade_level
    @student_class = StudentClass.find_by_id(params[:student_class_id])
    @student_class.update_attribute(:grade, params[:student_class][:grade])
    flash[:notice] = "Class grade level changed."
  end

  def send_parent_signup_request
    #SEND EMAIL TO params[:parent_email]
    begin
	  @teacher = current_user
	  @enrollment = Enrollment.get_roster_entry_for_enrollment_with_student_bool(params[:enrollment_id]).first
      @student = Student.find(params[:student_id])
	  email_index = "#{@student.id}_parent_email"
      tid = current_user.id
      parent_email = params[email_index].strip
      ParentNotifier.deliver_create_parent_account parent_email,@student,tid
      @ppr = PendingParentRequest.find_by_email_and_teacher_user_id_and_student_id(parent_email,@tid, @student.id)
      @ppr = PendingParentRequest.create!(:email => parent_email, :student_id => @student.id, :teacher_user_id => tid) unless !@ppr.nil?
      set_flash(:notice, "The request has been sent")
    rescue Exception => e
      set_flash(:warning, "The request has not been sent")
    end
  end
  
  def acknowledge_changed_email
    @pg_id = params[:pg_id]
    @pg_email = params[:pg_email]
    @student_parent = StudentParent.find_all_by_parent_id(@pg_id)
    @student_parent.each do |pge|
      pge.update_attribute(:changed_email, false)
    end
  end

  def delete_request
    @tid = params[:id].to_i
    @request_id = params[:request]
    @class = params[:class]
    @ppr = PendingParentRequest.find(@request_id)
    if(@ppr.teacher_user_id == @tid)
      @ppr.destroy
    else
      set_flash(:warning, "You cannot delete a request sent by another teacher!")
    end
    redirect_to(:controller => :folder, :action => :index, :id => @class)
    return
  end

  def log_in_as
    find_user_or_bounce
    session[:user] = @user
    set_flash :notice, "Logged in successfully!"
    #start = start_page(@user)
	#teachers can only log in as students. which means we force them to the student page and we want them to be in the same class 
    redirect_to :controller => "/tutor/folder/index/#{params[:student_class_id]}"
  end
  
   def search_student_name
	student_first_name = params[:student_first_name]
	student_last_name = params[:student_last_name]
	student_class_id = params[:student_class_id]
	student_state_checkbox = params[:student_state_checkbox]
	
	# get rid of blank spaces and upper name
	if !student_first_name.nil?
		student_first_name = student_first_name.gsub(/\s+/, "")
		student_first_name = student_first_name.upcase
	end
	if !student_last_name.nil?
		student_last_name = student_last_name.gsub(/\s+/, "")
		student_last_name = student_last_name.upcase
	end
	
	# Search with fist name, last name or both, also search out all names start with the strings put in search box
	student_sql_request = "SELECT ud.first_name, ud.middle_name, ud.last_name, ur.id, u.login, u.account_state FROM user_details ud 
						JOIN users u ON ud.user_id = u.id
						JOIN user_roles ur ON ud.user_id = ur.user_id
						WHERE ud.user_id IN(
							SELECT user_id FROM user_roles WHERE location_id IN (SELECT location_id FROM user_roles WHERE id IN (
								SELECT teacher_id FROM teacher_classes WHERE student_class_id = #{student_class_id})) 
								AND type = 'Student') 
								AND ur.user_id NOT IN(SELECT user_id FROM user_roles WHERE type != 'Student') 
								AND ur.role_id = 4"
	if !student_first_name.nil? and student_first_name.length != 0
		student_sql_request += " AND upper(ud.first_name) LIKE \'#{student_first_name}%\'"
	end
	if !student_last_name.nil? and student_last_name.length != 0
		student_sql_request += " AND upper(ud.last_name) LIKE \'#{student_last_name}%\'"
	end
	if student_state_checkbox == "disabled"
		student_sql_request += " AND u.account_state= 'Enabled' "
	end
	student_sql_request += "ORDER BY u.login"
	
	students = ActiveRecord::Base.connection.execute(student_sql_request)
	searched_students = []
	if students.result[0].nil?
		student = Hash.new
		student[:is_find] = false
		searched_students.push(student)
	else
		len = students.result.length
		for i in 0..len-1
			student = Hash.new
			student[:is_find] = true
			student[:first_name] = students.result[i][0]
			student[:middle_name] = students.result[i][1]
			student[:last_name] = students.result[i][2]
			student[:login] = students.result[i][4]
			student[:account_state] = students.result[i][5]
			student[:student_id] = students.result[i][3]
			
			# Find all the teacher of active classes this student is currently enrolling in 
			teacher_sql_request = "SELECT first_name, middle_name, last_name FROM user_details WHERE user_id IN(
									SELECT user_id FROM user_roles WHERE id IN(
										SELECT teacher_id FROM teacher_classes WHERE student_class_id IN(
												SELECT student_class_id FROM enrollments WHERE student_id = '#{student[:student_id]}' 
												AND enrollment_state_id = 1)
											AND student_class_id NOT IN(SELECT id FROM student_classes WHERE enabled = 'f')))"
			teachers = ActiveRecord::Base.connection.execute(teacher_sql_request)
			if teachers.result[0].nil?
				student[:teacher_list] = ' '
			else
				teacher_list = ''
				len = teachers.result.length
				for j in 0..len-2
					teacher_list += teachers.result[j][0] + ' ' + teachers.result[j][1] + ' ' + teachers.result[j][2] + ', ' 
				end
				teacher_list += teachers.result[len-1][0] + ' ' + teachers.result[len-1][1] + ' ' + teachers.result[len-1][2]
				student[:teacher_list] = teacher_list
			end
			searched_students.push(student)
		end
		
	end
	render :text => searched_students.to_json
  end
 
  def disable_account_state
	student_id = params[:student_id]
	disable_sql_request = "UPDATE users SET account_state='Disabled' WHERE id IN(
								SELECT user_id FROM user_roles WHERE id = #{student_id})"
	ActiveRecord::Base.connection.execute(disable_sql_request)
	render :text => "disabled successfully"
  end
  
  def enable_account_state
	student_id = params[:student_id]
	enable_sql_request = "UPDATE users SET account_state='Enabled' WHERE id IN(
								SELECT user_id FROM user_roles WHERE id = #{student_id})"
	ActiveRecord::Base.connection.execute(enable_sql_request)
	render :text => "enabled successfully"
  end
 
private
  def bounce(warning = nil)
    set_flash(:warning, warning) unless warning.nil?
    redirect_to(:action => :index)
    nil
  end
  

  
  def set_random_asignments_for_each_kid student_class, experiment
    
    condition_ids = Experiment.find_by_name(experiment.to_s).experiment_conditions.collect{|condition| condition.id}
    students = student_class.students
    class_assignments = student_class.class_assignments
    UserAssignmentCondition.transaction do
      students.each do |student|
        class_assignments.each do |class_assignment|
          UserAssignmentCondition.create(
            :user_id                          => student.user_id,
            :class_assignment_id              => class_assignment.id,
            :experiment_condition_id          => condition_ids[rand(condition_ids.size)],
            :created_at                       => Time.now
          )
        end
      end
    end
  end

  def find_user_or_bounce
    return true if (@user = User.find params[:id])
    set_flash  :warning, 'Could not find user ' << params[:id]
    redirect_to :action => :index
  end
  
 

=begin
  # Return the number of new comments since the user last visited the comment page
  def new_comments_since_last_visit
    last_visited_arr = CommentAction.find_by_sql("select last_visited from comment_actions where user_id = #{current_user.id}")
    last_visited = last_visited_arr.first
    if last_visited.nil?
      count_arr = ViewableComment.find_by_sql("select count(*) from viewable_comments where user_id = #{current_user.id}")
      return count_arr.first.count.to_i
    end


    count_arr = ViewableComment.find_by_sql("select count(*) from comments where id in(
                select comment_id from viewable_comments where user_id = #{current_user.id} AND (deleted = 'false' OR deleted IS NULL)) AND created_at > (
                select last_visited from comment_actions where user_id = #{current_user.id})")
    return count_arr.first.count.to_i

  end
=end
end

