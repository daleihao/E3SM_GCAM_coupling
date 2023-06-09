module cam_restart
!----------------------------------------------------------------------- 
! 
! module to handle reading and writing of the master restart files.
!
!----------------------------------------------------------------------- 
   use shr_kind_mod,     only: r8 => shr_kind_r8, cl=>shr_kind_cl
   use spmd_utils,       only: masterproc
   use ppgrid,           only: begchunk, endchunk
   use pmgrid,           only: plev, plevp, plat
   use rgrid,            only: nlon, wnummax, fullgrid
   use ioFileMod,        only: getfil, opnfil
   use cam_abortutils,   only: endrun
   use camsrfexch,       only: cam_in_t, cam_out_t     
   use dyn_comp,         only: dyn_import_t, dyn_export_t
   use perf_mod,         only: t_startf, t_stopf

#ifdef SPMD
   use mpishorthand,     only: mpicom, mpir8, mpiint, mpilog
#endif
   use units,            only: getunit
   use shr_kind_mod,     only: shr_kind_cl
   use cam_logfile,      only: iulog
   use pio,              only: file_desc_t, pio_global, pio_noerr, pio_offset_kind,&
                               pio_seterrorhandling, pio_bcast_error, pio_internal_error, &
                               pio_inq_att, pio_def_dim, pio_enddef, &
                               pio_get_att, pio_put_att, pio_closefile

   implicit none
   private
   save

   ! Public interfaces

   public restart_defaultopts    ! initialize namelist variables
   public restart_setopts        ! set values of namelist variables
   public restart_printopts      ! print module options to log
   public cam_write_restart      ! Write the master restart file out
   public cam_read_restart       ! Read the master restart file in
   public get_restcase           ! Get the caseid of the restart file being read in
   public get_restartdir         ! Get the directory name of the restart file being read in

   ! Private data

   integer, parameter :: uninit_int = -999999999

   integer, parameter :: nlen = 256       ! Length of character strings
   character(len=nlen):: pname = ' '      ! Full restart pathname
   character(shr_kind_cl) :: tcase = ' '  ! Read in previous case name

   ! Type of restart run
   logical :: nlres                       ! true => restart or branch run
   logical :: lbrnch                      ! true => branch run

   ! Filename specifiers for master restart filename
   ! (%c = caseid, $y = year, $m = month, $d = day, $s = seconds in day, %t = number)
   character(len=nlen) :: rfilename_spec = '%c.eam.r.%y-%m-%d-%s.nc'

   integer :: nsds = -1            ! Logical unit number for restart pointer file

   ! Filenames used for restart or branch
   character(len=nlen) :: rest_pfile = './rpointer.atm' ! Restart pointer file contains name of most recently
                                                        ! written restart file
   character(len=nlen) :: cam_branch_file = ' '         ! Filepath of primary restart file for a branch run

!-----------------------------------------------------------------------

!=========================================================================================
CONTAINS
!=========================================================================================

subroutine restart_defaultopts( &
   cam_branch_file_out            )
  !----------------------------------------------------------------------- 
  ! Purpose: Return default runtime options
  !-----------------------------------------------------------------------
  
  character(len=nlen), intent(out), optional :: cam_branch_file_out
  !-----------------------------------------------------------------------

  if ( present(cam_branch_file_out) ) then
     cam_branch_file_out = cam_branch_file
  endif
  
end subroutine restart_defaultopts

!================================================================================================

subroutine restart_setopts( nsrest, cam_branch_file_in )
  !----------------------------------------------------------------------- 
  ! Purpose: Set runtime options
  !-----------------------------------------------------------------------
  use cam_instance, only: inst_suffix
  
  integer,             intent(in)           :: nsrest
  character(len=nlen), intent(in), optional :: cam_branch_file_in
  
  integer :: numset=0
  integer :: rcode
  !-----------------------------------------------------------------------

  ! Set pointer file name based on instance suffix
  rest_pfile = trim(rest_pfile) // trim(inst_suffix)

  rfilename_spec = '%c.eam' // trim(inst_suffix) //'.r.%y-%m-%d-%s.nc'

  ! Set continuation run flags
  if (nsrest==0) then
     nlres  = .false.
     lbrnch = .false.
  else if (nsrest==1) then
     nlres  = .true.
     lbrnch = .false.
  else if (nsrest==3) then
     nlres  = .true.
     lbrnch = .true.
  else
     call endrun ('restart_setopts: not a valid option for nsrest (should be 0, 1 or 3)')
  endif
  
  if ( present(cam_branch_file_in) ) then
     cam_branch_file = cam_branch_file_in
  endif
  
  ! If branch set restart filepath to path given on namelist
  if ( lbrnch ) call set_restart_filepath( cam_branch_file )
  
end subroutine restart_setopts

!=========================================================================================

subroutine restart_printopts

   write(iulog,*)'Summary of restart module options:'
   write(iulog,*)'  Restart pointer file is: ',trim(rest_pfile)
   if (lbrnch) then
      write(iulog,*)'  Branch run will start from: ',trim(cam_branch_file)
   end if
end subroutine restart_printopts

!=========================================================================================

   subroutine cam_write_restart( cam_in, cam_out, dyn_out, pbuf2d, &
	                         yr_spec, mon_spec, day_spec, sec_spec )

!----------------------------------------------------------------------- 
! 
! Purpose: 
! Write the primary, secondary, and history buffer regeneration files.
! 
! Method: 
! The cpp SPMD definition provides for the funnelling of all program i/o
! through the master processor. Processor 0 either reads restart/history
! data from the disk and distributes it to all processors, or collects
! data from all processors and writes it to disk.
! 
! Author: 
! 
!----------------------------------------------------------------------- 
     use physics_buffer,            only: physics_buffer_desc
      use cam_history,      only: write_restart_history, init_restart_history
      use radiation,        only: radiation_do
      use time_manager,     only: timemgr_write_restart
      use filenames,        only: caseid, interpret_filename_spec

      use time_manager,     only: timemgr_write_restart, timemgr_init_restart
      use restart_dynamics, only: write_restart_dynamics, init_restart_dynamics
      use restart_physics,  only: write_restart_physics, init_restart_physics
      use cam_pio_utils,    only: cam_pio_createfile
      use spmd_utils,       only: iam, mpicom
      !
      ! Arguments
      !
      type(cam_in_t),      intent(in) :: cam_in(begchunk:endchunk)
      type(cam_out_t),     intent(in) :: cam_out(begchunk:endchunk)
      
      type(dyn_export_t),  intent(in) :: dyn_out
      
      type(physics_buffer_desc), pointer  :: pbuf2d(:,:)

      integer            , intent(in), optional :: yr_spec         ! Simulation year
      integer            , intent(in), optional :: mon_spec        ! Simulation month
      integer            , intent(in), optional :: day_spec        ! Simulation day
      integer            , intent(in), optional :: sec_spec        ! Seconds into current simulation day
      !
      ! Local workspace
      !
      integer ioerr                 ! write error status
      character(len=nlen) :: fname  ! Restart filename
      integer :: ierr
      type(file_desc_t) :: File


      !-----------------------------------------------------------------------
      ! Write the primary restart datasets
      !-----------------------------------------------------------------------
#ifdef DEBUG
      write(iulog,*)'Entered CAM_WRITE_RESTART: writing nstep+1=',nstep+1, ' data to restart file'
#endif

      !-----------------------------------------------------------------------
      ! Write the master restart dataset
      !-----------------------------------------------------------------------
      call t_startf("write_restart_master")

      if (present(yr_spec).and.present(mon_spec).and.present(day_spec).and.present(sec_spec)) then
         fname = interpret_filename_spec( rfilename_spec, &
              yr_spec=yr_spec, mon_spec=mon_spec, day_spec=day_spec, sec_spec= sec_spec )
      else
         fname = interpret_filename_spec( rfilename_spec )
      end if

      call cam_pio_createfile(File, trim(fname))
      call timemgr_init_restart(File)

      call t_startf("init_restart_dynamics")
      call init_restart_dynamics(File, dyn_out)
      call t_stopf("init_restart_dynamics")

      call t_startf("init_restart_physics")
      call init_restart_physics(File, pbuf2d)
      call t_stopf("init_restart_physics")

      call init_restart_history(File)

      ierr = PIO_Put_att(File, PIO_GLOBAL, 'caseid', caseid)
      if(.not.fullgrid) then
         ierr = PIO_Put_att(File, PIO_GLOBAL, 'NLON', nlon)
         ierr = PIO_Put_att(File, PIO_GLOBAL, 'WNUMMAX', wnummax)
      end if
      ierr = pio_enddef(File)

      call t_stopf("write_restart_master")

      !-----------------------------------------------------------------------
      ! Dynamics, physics, History
      !-----------------------------------------------------------------------

      call t_startf("timemgr_write_restart")
      call timemgr_write_restart(File)
      call t_stopf("timemgr_write_restart")

      call t_startf("write_restart_dynamics")
      call write_restart_dynamics(File, dyn_out)
      call t_stopf("write_restart_dynamics")

      call t_startf("write_restart_physics")
      call write_restart_physics(File, cam_in, cam_out, pbuf2d)
      call t_stopf("write_restart_physics")

      call t_startf("write_restart_history")
      if (present(yr_spec).and.present(mon_spec).and.&
           present(day_spec).and.present(sec_spec)) then
         call write_restart_history ( File, &
              yr_spec=yr_spec, mon_spec=mon_spec, day_spec=day_spec, sec_spec= sec_spec )
      else
         call write_restart_history( File )
      end if
      call t_stopf("write_restart_history")

      call pio_closefile(File)
      !-----------------------------------------------------------------------
      ! Close the master restart file
      !-----------------------------------------------------------------------

      if (masterproc) then
	 pname = fname

         call t_startf("write_rest_pfile")
         call write_rest_pfile()
         call t_stopf("write_rest_pfile")
      end if

   end subroutine cam_write_restart

!#######################################################################

   subroutine cam_read_restart( cam_in, cam_out, dyn_in, dyn_out, pbuf2d, stop_ymd, stop_tod, NLFileName )

!----------------------------------------------------------------------- 
! 
! Purpose: 
! Acquire and position the restart, master, primary and secondary
! datasets for a continuation run
! 
! Method: 
! 
! Author: 
! 
!-----------------------------------------------------------------------
     use physics_buffer, only: physics_buffer_desc
      use restart_physics,  only: read_restart_physics
      use restart_dynamics, only: read_restart_dynamics
      use chem_surfvals,    only: chem_surfvals_init
      use camsrfexch,       only: hub2atm_alloc, atm2hub_alloc
#if (defined SPMD)
      use spmd_dyn,         only: spmdbuf
#endif
      use cam_history,      only: read_restart_history

      use cam_pio_utils,    only: cam_pio_openfile, clean_iodesc_list
      use spmd_utils,       only: iam, mpicom
      use time_manager,     only: timemgr_read_restart, timemgr_restart
      use filenames,        only: caseid, brnch_retain_casename
      use ref_pres,         only: ref_pres_init

!
!-----------------------------------------------------------------------
!
! Arguments
!
   type(cam_in_t),     pointer     :: cam_in(:)
   type(cam_out_t),    pointer     :: cam_out(:)
   type(dyn_import_t), intent(inout) :: dyn_in
   type(dyn_export_t), intent(inout) :: dyn_out
   type(physics_buffer_desc), pointer :: pbuf2d(:,:)
   character(len=*),   intent(in)  :: NLFileName
   integer,            intent(IN)  :: stop_ymd       ! Stop date (YYYYMMDD)
   integer,            intent(IN)  :: stop_tod       ! Stop time of day (sec)
!
! Local workspace
!
   character(len=nlen) :: locfn          ! Local filename
   character(len=nlen+40) :: errstr
   real(r8) :: tmp_rgrid(plat)
   integer :: ierr, xtype
   integer(PIO_OFFSET_KIND) :: slen
   type(file_desc_t) :: File
   logical :: filefound

      ! lbrnch is false for a restart run (nsrest=1), and true for a 
      ! branch run (nsrest=3).  Only read the restart pointer file for
      ! a restart run.
   if (.not.lbrnch) then
      call read_rest_pfile
   endif
  
!
!------------------------------------------------------------------------
! Obtain and read the master restart dataset 
!------------------------------------------------------------------------
!
#ifdef DEBUG
   if(masterproc) write(iulog,*)'READ_RESTART_MASTER: Reading master resart dataset'
#endif

!
! Obtain master restart dataset
!
   call getfil (pname, locfn)
   !-----------------------------------------------------------------------
   ! Master restart dataset
   !-----------------------------------------------------------------------
   inquire(FILE=trim(locfn), exist=filefound)

   if(.not.filefound) then
      write(errstr,*) 'Could not find restart file ', trim(locfn)
      call endrun(errstr)
   end if

   call cam_pio_openfile(File, trim(locfn), 0)
   ierr = pio_inq_att(File, pio_global, 'caseid', xtype, slen)
   ierr = PIO_Get_att(File, PIO_GLOBAL, 'caseid', tcase)
   tcase(slen+1:len(tcase))=''
      
! If these variables are not in the file the call will give an error 
!       which we can safely ignore
   call PIO_SetErrorHandling(File, PIO_BCAST_ERROR)
   ierr = pio_get_att(File, PIO_GLOBAL, 'NLON', tmp_rgrid)
   if(ierr==PIO_NOERR) nlon=tmp_rgrid
   ierr = pio_get_att(File, PIO_GLOBAL, 'WNUMMAX', tmp_rgrid)
   if(ierr==PIO_NOERR) wnummax=tmp_rgrid
   call PIO_SetErrorHandling(File, PIO_INTERNAL_ERROR)

   call t_startf('timemgr_read_restart')
   call timemgr_read_restart(File)
   call t_stopf('timemgr_read_restart')

   if(masterproc) then

      if (lbrnch .and. tcase==caseid .and. .not.brnch_retain_casename) then
         write(iulog,*) 'READ_RESTART_MASTER: Must change case name on branch run'
         write(iulog,*) 'Prev case = ',tcase,' current case = ',caseid
         call endrun
      end if

      write(iulog,*) 'Files for restart:'

   endif  ! end of if-masterproc

   ! Restart the time manager.
   call timemgr_restart( stop_ymd=stop_ymd, stop_tod=stop_tod )

      !-----------------------------------------------------------------------
      ! Dynamics, physics, History
      !-----------------------------------------------------------------------

   call initcom ()

   call t_startf('read_restart_dynamics')
   call read_restart_dynamics(File, dyn_in, dyn_out, NLFileName)   
   call t_stopf('read_restart_dynamics')

   call hub2atm_alloc( cam_in )
   call atm2hub_alloc( cam_out )


   ! Initialize physics grid reference pressures (needed by initialize_radbuffer)
   call ref_pres_init()

   call t_startf('read_restart_physics')
   call read_restart_physics( File, cam_in, cam_out, pbuf2d )
   call t_stopf('read_restart_physics')

   if (nlres .and. .not.lbrnch) then
      call t_startf('read_restart_history')
      call read_restart_history ( File )
      call t_stopf('read_restart_history')
   end if

   call pio_closefile(File)
   
   !-----------------------------------------------------------------------
   ! Allocate communication buffers for collective communications
   ! between physics and dynamics, if necessary
   !-----------------------------------------------------------------------

#if (defined SPMD)
   call spmdbuf ()
#endif

   ! Initialize ghg surface values.

   call chem_surfvals_init()

   call t_startf('clean_iodesc_list')
   call clean_iodesc_list()
   call t_stopf('clean_iodesc_list')

 end subroutine cam_read_restart

!#######################################################################

   subroutine write_rest_pfile
!----------------------------------------------------------------------- 
! 
! Purpose: 
!
! Write out the restart pointer file
!
!----------------------------------------------------------------------- 
   use cam_history,     only: get_ptapes, get_hist_restart_filepath, &
                              hstwr, get_hfilepath, nfils, mfilt
!-----------------------------------------------------------------------
   integer t      ! Tape number
   integer mtapes ! Number of tapes that are active

   if ( nsds == -1 ) nsds = getunit()
   call opnfil(rest_pfile, nsds, 'f')
   rewind nsds
   write (nsds,'(a)') trim(pname)
   write (nsds,'(//a,a)') '# The following lists the other files needed for restarts', &
                        ' (cam only reads the first line of this file).'
   write (nsds,'(a,a)') '# The files below refer to the files needed for the master restart file:', &
                       trim(pname)
!
! History files: Need restart history files when not a time-step to write history info
! Need: history files if they are not full
!
   mtapes = get_ptapes( )
   do t=1,mtapes
      if ( .not. hstwr(t) ) then
         write (nsds,'(a,a)') '# ', trim(get_hist_restart_filepath( t ))
      end if
      if ( nfils(t) > 0 .and. nfils(t) < mfilt(t) ) then
         write (nsds,'(a,a)') '# ', trim(get_hfilepath( t ))
      end if
   end do
   close (nsds)
   write(iulog,*)'(WRITE_REST_PFILE): successfully wrote local restart pointer file ',trim(rest_pfile)
   write(iulog,'("---------------------------------------")')
   end subroutine write_rest_pfile

!#######################################################################

   subroutine read_rest_pfile
!----------------------------------------------------------------------- 
! 
! Purpose: 
!
! Read the master restart file from the restart pointer file
!
!----------------------------------------------------------------------- 

   character(len=nlen) :: locfn        ! Local pathname for restart pointer file

   nsds = getunit()
   call opnfil (rest_pfile, nsds, 'f', status="old")
   read (nsds,'(a)') pname
   
   close(nsds)


   end subroutine read_rest_pfile

!#######################################################################

!-----------------------------------------------------------------------
! BOP
!
! !ROUTINE: set_restart_filepath
!
! !DESCRIPTION: Set the filepath of the specific type of restart file.
!
!-----------------------------------------------------------------------
! !INTERFACE:
subroutine set_restart_filepath( rgpath )
!
! !PARAMETERS:
!
  character(len=*), intent(in)  :: rgpath ! Full pathname to restart file
!
! EOP
!
  if ( trim(rgpath) == '' )then
     call endrun ('set_restart_filepath: rgpath sent into subroutine is empty')
  end if
  if ( rgpath(1:1) /= '/' )then
     call endrun ('set_restart_filepath: rgpath sent into subroutine is not an absolute pathname')
  end if
  if ( len_trim(rgpath) > nlen )then
     call endrun ('set_restart_filepath: rgpath is too long :'//rgpath)
  end if
  pname = trim(rgpath)
end subroutine set_restart_filepath

!#######################################################################

!-----------------------------------------------------------------------
! BOP
!
! !FUNCTION: get_restcase
!
! !DESCRIPTION: Get the caseid of the case being read in
!
!-----------------------------------------------------------------------
! !INTERFACE:
character(len=nlen) function get_restcase()
!
! EOP
!
  if ( trim(tcase) == '' )then
     call endrun ('GET_RESTCASE: caseid read in is empty, is this call after cam_read_restart?')
  end if
  get_restcase = tcase
end function get_restcase

!#######################################################################

!-----------------------------------------------------------------------
! BOP
!
! !FUNCTION: get_restartdir
!
! !DESCRIPTION: Get the directory of the restart file being read in
!
!-----------------------------------------------------------------------
! !INTERFACE:
character(len=nlen) function get_restartdir()
  use filenames,   only: get_dir
!
! EOP
!
  ! Uses pname, so will be updated after a restart file is written out
  if ( trim(pname) == '' )then
     call endrun ('GET_RESTDIR: restart filename is empty, is this call after cam_read_restart?')
  end if
  get_restartdir = get_dir(pname)
end function get_restartdir

!=========================================================================================

end module cam_restart
