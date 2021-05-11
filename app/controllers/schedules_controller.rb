# frozen_string_literal: true

class SchedulesController < ApplicationController
  include ConferenceHelper

  load_and_authorize_resource
  before_action :respond_to_options
  before_action :favourites
  load_resource :conference, find_by: :short_title
  load_resource :program, through: :conference, singleton: true, except: :index
  before_action :load_withdrawn_event_schedules, only: %i[show events]

  def show
    # TODO-SNAPCON: This route is currently not exposed, preferring to use `vertical_schedule`
    event_schedules = @program.selected_event_schedules(
      includes: [{ event: %i[event_type speakers submitter] }]
    )

    unless event_schedules
      redirect_to events_conference_schedule_path(@conference.short_title)
      return
    end

    respond_to do |format|
      format.xml do
        if event_schedules
          @events_xml = event_schedules.map(&:event).group_by { |event| event.time.to_date }
        end
      end
      format.ics do
        cal = Icalendar::Calendar.new
        cal = icalendar_proposals(cal, event_schedules.map(&:event), @conference)
        cal.publish
        render inline: cal.to_ical
      end

      format.html do
        @rooms = @conference.venue.rooms if @conference.venue
        @dates = @conference.start_date..@conference.end_date
        @step_minutes = @program.schedule_interval.minutes
        @conf_start = @conference.start_hour
        @conf_period = @conference.end_hour - @conf_start

        # the schedule takes you to today if it is a date of the schedule
        @current_day = @conference.current_conference_day
        @day = @current_day.present? ? @current_day : @dates.first
        if @current_day
          # the schedule takes you to the current time if it is beetween the start and the end time.
          @hour_column = @conference.hours_from_start_time(@conf_start, @conference.end_hour)
        end
        # Ids of the @event_schedules of confrmed self_organized tracks along with the selected_schedule_id
        @selected_schedules_ids = [@conference.program.selected_schedule_id]
        @conference.program.tracks.self_organized.confirmed.each do |track|
          @selected_schedules_ids << track.selected_schedule_id
        end
        @selected_schedules_ids.compact!
        @event_schedules_by_room_id = event_schedules.select { |s| @selected_schedules_ids.include?(s.schedule_id) }.group_by(&:room_id)
      end
    end
  end

  def events
    @dates = @conference.start_date..@conference.end_date
    # TODO: use the cachable method.
    @events_schedules = @program.selected_event_schedules(
      includes: [:room, { event: %i[track event_type speakers submitter] }]
    )

    # TODO: Refactor this -- "events for current user"
    if @events_schedules && current_user && @favourites
      @events_schedules = @events_schedules.select { |e| e.event.favourite_users.exists?(current_user.id) }
    end
    @events_schedules ||= []

    @unscheduled_events = if @program.selected_schedule
                            @program.events.confirmed - @events_schedules.map(&:event)
                          else
                            @program.events.confirmed
                          end
    if current_user && @favourites
      @unscheduled_events = @unscheduled_events.select { |e| e.favourite_users.exists?(current_user.id) }
    end

    day = @conference.current_conference_day
    @tag = day.strftime('%Y-%m-%d') if day
  end

  def happening_now
    # TODO: Adapt to include happening next.
    @events_schedules = get_happening_now_events_schedules(@conference)
    @current_time = Time.now.in_time_zone(@conference.timezone)

    respond_to do |format|
      format.html
      format.json { render json: @events_schedules.to_json(root: false, include: :event) }
    end
  end

  def vertical_schedule
    # TODO: Adapt to take in favorites param?
    dates = @conference.start_date..@conference.end_date
    # the schedule takes you to today if it is a date of the schedule
    current_day = @conference.current_conference_day
    @day = current_day.present? ? current_day : dates.first
    # TODO: Update method name.
    event_schedules = @program.event_schedule_for_fullcalendar

    unless event_schedules
      redirect_to events_conference_schedule_path(@conference.short_title)
      return
    end

    if @conference.venue
      @rooms = FullCalendarFormatter.rooms_to_resources(@conference.venue.rooms)
    end
    @event_schedules = FullCalendarFormatter.event_schedules_to_resources(event_schedules)
    @now = Time.now.in_time_zone(@conference.timezone).strftime('%FT%T%:z')
  end

  def app
    @qr_code = RQRCode::QRCode.new(conference_schedule_url).as_svg(offset: 20, color: '000', shape_rendering: 'crispEdges', module_size: 11)
  end

  private

  def favourites
    @favourites = params[:favourites] == 'true'
  end

  def respond_to_options
    if request.options?
      respond_to do |format|
        format.html { head :ok }
      end
    end
  end

  def load_withdrawn_event_schedules
    # Avoid making repetitive EXISTS queries for these later.
    # See usage in EventsHelper#canceled_replacement_event_label
    @withdrawn_event_schedules = EventSchedule.withdrawn_or_canceled_event_schedules(@program.schedule_ids)
  end
end
