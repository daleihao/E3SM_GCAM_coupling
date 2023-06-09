module prep_atm_mod

  use shr_kind_mod,     only: r8 => SHR_KIND_R8
  use shr_kind_mod,     only: cs => SHR_KIND_CS
  use shr_kind_mod,     only: cl => SHR_KIND_CL
  use shr_sys_mod,      only: shr_sys_abort, shr_sys_flush
  use seq_comm_mct,     only: num_inst_atm, num_inst_ocn, num_inst_ice, num_inst_lnd, num_inst_xao, &
       num_inst_frc, num_inst_max, num_inst_iac, CPLID, ATMID, logunit
  use seq_comm_mct,     only: seq_comm_getData=>seq_comm_setptrs
  use seq_infodata_mod, only: seq_infodata_type, seq_infodata_getdata
  use seq_map_type_mod
  use seq_map_mod
  use seq_flds_mod
  use t_drv_timers_mod
  use mct_mod
  use perf_mod
  use component_type_mod, only: component_get_x2c_cx, component_get_c2x_cx
  use component_type_mod, only: atm, lnd, ocn, ice, iac

  implicit none
  save
  PRIVATE

  !--------------------------------------------------------------------------
  ! Public interfaces
  !--------------------------------------------------------------------------

  public :: prep_atm_init
  public :: prep_atm_mrg

  public :: prep_atm_get_l2x_ax
  public :: prep_atm_get_i2x_ax
  public :: prep_atm_get_o2x_ax
  public :: prep_atm_get_z2x_ax

  public :: prep_atm_calc_l2x_ax
  public :: prep_atm_calc_i2x_ax
  public :: prep_atm_calc_o2x_ax
  public :: prep_atm_calc_z2x_ax

  public :: prep_atm_get_mapper_So2a
  public :: prep_atm_get_mapper_Fo2a
  public :: prep_atm_get_mapper_Sl2a
  public :: prep_atm_get_mapper_Fl2a
  public :: prep_atm_get_mapper_Si2a
  public :: prep_atm_get_mapper_Fi2a
  public :: prep_atm_get_mapper_Fz2a

  !--------------------------------------------------------------------------
  ! Private interfaces
  !--------------------------------------------------------------------------

  private :: prep_atm_merge

  !--------------------------------------------------------------------------
  ! Private data
  !--------------------------------------------------------------------------

  ! mappers
  type(seq_map), pointer :: mapper_So2a
  type(seq_map), pointer :: mapper_Sl2a
  type(seq_map), pointer :: mapper_Si2a
  type(seq_map), pointer :: mapper_Sz2a
  type(seq_map), pointer :: mapper_Fo2a           ! needed for seq_frac_init
  type(seq_map), pointer :: mapper_Fl2a           ! needed for seq_frac_init
  type(seq_map), pointer :: mapper_Fi2a           ! needed for seq_frac_init
  type(seq_map), pointer :: mapper_Fz2a

  ! attribute vectors
  type(mct_aVect), pointer :: l2x_ax(:)   ! Lnd export, atm grid, cpl pes - allocated in driver
  type(mct_aVect), pointer :: i2x_ax(:)   ! Ice export, atm grid, cpl pes - allocated in driver
  type(mct_aVect), pointer :: o2x_ax(:)   ! Ocn export, atm grid, cpl pes - allocated in driver
  type(mct_aVect), pointer :: z2x_ax(:)   ! Iac export, atm grid, cpl pes - allocated in driver

  ! other module variables
  integer :: mpicom_CPLID  ! MPI cpl communicator
  logical :: iamroot_CPLID ! .true. => CPLID masterproc
  logical :: samegrid_al   ! samegrid atm and land
  !================================================================================================

contains

  !================================================================================================

  subroutine prep_atm_init(infodata, ocn_c2_atm, ice_c2_atm, lnd_c2_atm)

    !---------------------------------------------------------------
    ! Description
    ! Initialize module attribute vectors and  mappers
    !
    ! Arguments
    type (seq_infodata_type) , intent(inout) :: infodata
    logical                  , intent(in)    :: ocn_c2_atm ! .true.  => ocn to atm coupling on
    logical                  , intent(in)    :: ice_c2_atm ! .true.  => ice to atm coupling on
    logical                  , intent(in)    :: lnd_c2_atm ! .true.  => lnd to atm coupling on
    !
    ! Local Variables
    integer                          :: lsize_a
    integer                          :: eli, eii, emi, ezi
    logical                          :: samegrid_ao    ! samegrid atm and ocean
    logical                          :: samegrid_az ! samegrid atm and iac
    logical                          :: esmf_map_flag  ! .true. => use esmf for mapping
    logical                          :: atm_present    ! .true.  => atm is present
    logical                          :: ocn_present    ! .true.  => ocn is present
    logical                          :: ice_present    ! .true.  => ice is present
    logical                          :: lnd_present    ! .true.  => lnd is prsent
    logical                          :: iac_present    ! .true.  => iac is prsent
    character(CL)                    :: ocn_gnam       ! ocn grid
    character(CL)                    :: atm_gnam       ! atm grid
    character(CL)                    :: lnd_gnam       ! lnd grid
    character(CL)                    :: iac_gnam       ! iac grid
    type(mct_avect), pointer         :: a2x_ax
    character(*), parameter          :: subname = '(prep_atm_init)'
    character(*), parameter          :: F00 = "('"//subname//" : ', 4A )"
    !---------------------------------------------------------------

    call seq_infodata_getData(infodata, &
         atm_present=atm_present,       &
         ocn_present=ocn_present,       &
         ice_present=ice_present,       &
         lnd_present=lnd_present,       &
         iac_present=iac_present,       &
         atm_gnam=atm_gnam,             &
         ocn_gnam=ocn_gnam,             &
         lnd_gnam=lnd_gnam,             &
         iac_gnam=iac_gnam,             &
         esmf_map_flag=esmf_map_flag)

    allocate(mapper_So2a)
    allocate(mapper_Sl2a)
    allocate(mapper_Si2a)
    allocate(mapper_Fo2a)
    allocate(mapper_Fl2a)
    allocate(mapper_Fi2a)
    allocate(mapper_Fz2a)

    if (atm_present) then

       call seq_comm_getData(CPLID, &
            mpicom=mpicom_CPLID, iamroot=iamroot_CPLID)

       a2x_ax => component_get_c2x_cx(atm(1))
       lsize_a = mct_aVect_lsize(a2x_ax)

       allocate(l2x_ax(num_inst_lnd))
       do eli = 1,num_inst_lnd
          call mct_aVect_init(l2x_ax(eli), rList=seq_flds_l2x_fields, lsize=lsize_a)
          call mct_aVect_zero(l2x_ax(eli))
       end do
       allocate(o2x_ax(num_inst_max))
       do emi = 1,num_inst_max
          call mct_aVect_init(o2x_ax(emi), rList=seq_flds_o2x_fields, lsize=lsize_a)
          call mct_aVect_zero(o2x_ax(emi))
       enddo
       allocate(i2x_ax(num_inst_ice))
       do eii = 1,num_inst_ice
          call mct_aVect_init(i2x_ax(eii), rList=seq_flds_i2x_fields, lsize=lsize_a)
          call mct_aVect_zero(i2x_ax(eii))
       enddo
       allocate(z2x_ax(num_inst_iac))
       do ezi = 1,num_inst_iac
          call mct_aVect_init(z2x_ax(ezi), rList=seq_flds_z2x_fields, lsize=lsize_a)
          call mct_aVect_zero(z2x_ax(ezi))
       enddo

       samegrid_al = .true.
       samegrid_ao = .true.
       samegrid_az = .true.
       if (trim(atm_gnam) /= trim(lnd_gnam)) samegrid_al = .false.
       if (trim(atm_gnam) /= trim(ocn_gnam)) samegrid_ao = .false.
       if (trim(atm_gnam) /= trim(iac_gnam)) samegrid_az = .false.

       if (ocn_c2_atm) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_So2a'
          end if
          call seq_map_init_rcfile(mapper_So2a, ocn(1), atm(1), &
               'seq_maps.rc','ocn2atm_smapname:','ocn2atm_smaptype:',samegrid_ao, &
               'mapper_So2a initialization',esmf_map_flag)
       end if

       ! needed for domain checking
       if (ocn_present) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_Fo2a'
          end if
          call seq_map_init_rcfile(mapper_Fo2a, ocn(1), atm(1), &
               'seq_maps.rc','ocn2atm_fmapname:','ocn2atm_fmaptype:',samegrid_ao, &
               'mapper_Fo2a initialization',esmf_map_flag)
       endif
       call shr_sys_flush(logunit)

       if (ice_c2_atm) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_Si2a'
          end if
          call seq_map_init_rcfile(mapper_Si2a, ice(1), atm(1), &
               'seq_maps.rc','ice2atm_smapname:','ice2atm_smaptype:',samegrid_ao, &
               'mapper_Si2a initialization',esmf_map_flag)
       end if

       ! needed for domain checking
       if (ice_present) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_Fi2a'
          end if
          call seq_map_init_rcfile(mapper_Fi2a, ice(1), atm(1), &
               'seq_maps.rc','ice2atm_fmapname:','ice2atm_fmaptype:',samegrid_ao, &
               'mapper_Fi2a initialization',esmf_map_flag)
       endif
       call shr_sys_flush(logunit)

       ! needed for domain checking
       if (lnd_present) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_Fl2a'
          end if
          call seq_map_init_rcfile(mapper_Fl2a, lnd(1), atm(1), &
               'seq_maps.rc','lnd2atm_fmapname:','lnd2atm_fmaptype:',samegrid_al, &
               'mapper_Fl2a initialization',esmf_map_flag)
       endif
       call shr_sys_flush(logunit)

       if (lnd_c2_atm) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_Sl2a'
          end if
          call seq_map_init_rcfile(mapper_Sl2a, lnd(1), atm(1), &
               'seq_maps.rc','lnd2atm_smapname:','lnd2atm_smaptype:',samegrid_al, &
               'mapper_Sl2a initialization',esmf_map_flag)
       end if

       ! needed for domain checking
       if (iac_present) then
          if (iamroot_CPLID) then
             write(logunit,*) ' '
             write(logunit,F00) 'Initializing mapper_Fz2a'
          end if

          call seq_map_init_rcfile(mapper_Fz2a, iac(1), atm(1), &
               'seq_maps.rc','iac2atm_fmapname:','iac2atm_fmaptype:',samegrid_az, &
               'mapper_Fz2a initialization',esmf_map_flag)
       endif
       call shr_sys_flush(logunit)

    end if

  end subroutine prep_atm_init

  !================================================================================================

  subroutine prep_atm_mrg(infodata, fractions_ax, xao_ax, timer_mrg)

    !---------------------------------------------------------------
    ! Description
    ! Prepare run phase, including running the merge
    !
    ! Arguments
    type(seq_infodata_type) , intent(in)    :: infodata
    type(mct_aVect)         , intent(in)    :: fractions_ax(:)
    type(mct_aVect)         , intent(in)    :: xao_ax(:)
    character(len=*)        , intent(in)    :: timer_mrg
    !
    ! Local Variables
    integer                  :: eli, eoi, eii, exi, efi, eai, emi, ezi
    type(mct_avect), pointer :: x2a_ax
    character(*), parameter  :: subname = '(prep_atm_mrg)'
    character(*), parameter  :: F00 = "('"//subname//" : ', 4A )"
    !---------------------------------------------------------------

    call t_drvstartf (trim(timer_mrg),barrier=mpicom_CPLID)
    do eai = 1,num_inst_atm
       ! Use fortran mod to address ensembles in merge
       eli = mod((eai-1),num_inst_lnd) + 1
       eoi = mod((eai-1),num_inst_ocn) + 1
       eii = mod((eai-1),num_inst_ice) + 1
       exi = mod((eai-1),num_inst_xao) + 1
       efi = mod((eai-1),num_inst_frc) + 1
       emi = mod((eai-1),num_inst_max) + 1
       ezi = mod((eai-1),num_inst_iac) + 1

       x2a_ax => component_get_x2c_cx(atm(eai)) ! This is actually modifying x2a_ax
       call prep_atm_merge(l2x_ax(eli), o2x_ax(emi), xao_ax(exi), &
            i2x_ax(eii), z2x_ax(ezi), &
            fractions_ax(efi), x2a_ax)
    enddo
    call t_drvstopf  (trim(timer_mrg))

  end subroutine prep_atm_mrg

  !================================================================================================

  subroutine prep_atm_merge( l2x_a, o2x_a, xao_a, i2x_a, z2x_a, fractions_a, x2a_a )

    !-----------------------------------------------------------------------
    !
    ! Arguments
    type(mct_aVect), intent(in)    :: l2x_a
    type(mct_aVect), intent(in)    :: o2x_a
    type(mct_aVect), intent(in)    :: xao_a
    type(mct_aVect), intent(in)    :: i2x_a
    type(mct_aVect), intent(in)    :: z2x_a
    type(mct_aVect), intent(in)    :: fractions_a
    type(mct_aVect), intent(inout) :: x2a_a
    !
    ! Local workspace
    real(r8) :: fracl, fraci, fraco, fracz
    integer  :: n,ka,ki,kl,ko,kx,kof,kif,klf,kzf,i,i1,o1,kz
    integer  :: lsize
    integer  :: index_x2a_Sf_lfrac
    integer  :: index_x2a_Sf_ifrac
    integer  :: index_x2a_Sf_ofrac
    integer  :: index_x2a_Sf_zfrac
    character(CL),allocatable :: field_atm(:)   ! string converted to char
    character(CL),allocatable :: field_lnd(:)   ! string converted to char
    character(CL),allocatable :: field_ice(:)   ! string converted to char
    character(CL),allocatable :: field_iac(:)   ! string converted to char
    character(CL),allocatable :: field_xao(:)   ! string converted to char
    character(CL),allocatable :: field_ocn(:)   ! string converted to char
    character(CL),allocatable :: itemc_atm(:)   ! string converted to char
    character(CL),allocatable :: itemc_lnd(:)   ! string converted to char
    character(CL),allocatable :: itemc_ice(:)   ! string converted to char
    character(CL),allocatable :: itemc_iac(:)   ! string converted to char
    character(CL),allocatable :: itemc_xao(:)   ! string converted to char
    character(CL),allocatable :: itemc_ocn(:)   ! string converted to char
    logical :: iamroot
    character(CL),allocatable :: mrgstr(:)   ! temporary string
    character(CL) :: fracstr
    logical, save :: first_time = .true.
    type(mct_aVect_sharedindices),save :: l2x_sharedindices
    type(mct_aVect_sharedindices),save :: o2x_sharedindices
    type(mct_aVect_sharedindices),save :: i2x_sharedindices
    type(mct_aVect_sharedindices),save :: z2x_sharedindices
    type(mct_aVect_sharedindices),save :: xao_sharedindices
    logical, pointer, save :: lmerge(:),imerge(:),xmerge(:),omerge(:),zmerge(:)
    integer, pointer, save :: lindx(:), iindx(:), oindx(:),xindx(:),zindx(:)
    integer, save          :: naflds, nlflds,niflds,noflds,nxflds,nzflds
    character(*), parameter   :: subname = '(prep_atm_merge) '
    !-----------------------------------------------------------------------
    !
    call seq_comm_getdata(CPLID, iamroot=iamroot)

    if (first_time) then

       naflds = mct_aVect_nRattr(x2a_a)
       nlflds = mct_aVect_nRattr(l2x_a)
       niflds = mct_aVect_nRattr(i2x_a)
       nzflds = mct_aVect_nRattr(z2x_a)
       noflds = mct_aVect_nRattr(o2x_a)
       nxflds = mct_aVect_nRattr(xao_a)

       allocate(lindx(naflds), lmerge(naflds))
       allocate(iindx(naflds), imerge(naflds))
       allocate(xindx(naflds), xmerge(naflds))
       allocate(zindx(naflds), zmerge(naflds))
       allocate(oindx(naflds), omerge(naflds))
       allocate(field_atm(naflds), itemc_atm(naflds))
       allocate(field_lnd(nlflds), itemc_lnd(nlflds))
       allocate(field_ice(niflds), itemc_ice(niflds))
       allocate(field_iac(nzflds), itemc_iac(nzflds))
       allocate(field_ocn(noflds), itemc_ocn(noflds))
       allocate(field_xao(nxflds), itemc_xao(nxflds))
       allocate(mrgstr(naflds))

       lindx(:) = 0
       iindx(:) = 0
       xindx(:) = 0
       oindx(:) = 0
       zindx(:) = 0
       lmerge(:)  = .true.
       imerge(:)  = .true.
       xmerge(:)  = .true.
       omerge(:)  = .true.
       zmerge(:)  = .true.

       do ka = 1,naflds
          field_atm(ka) = mct_aVect_getRList2c(ka, x2a_a)
          itemc_atm(ka) = trim(field_atm(ka)(scan(field_atm(ka),'_'):))
       enddo
       do kl = 1,nlflds
          field_lnd(kl) = mct_aVect_getRList2c(kl, l2x_a)
          itemc_lnd(kl) = trim(field_lnd(kl)(scan(field_lnd(kl),'_'):))
       enddo
       do kz = 1,nzflds
          field_iac(kz) = mct_aVect_getRList2c(kz, z2x_a)
          itemc_iac(kz) = trim(field_iac(kz)(scan(field_iac(kz),'_'):))
       enddo
       do ki = 1,niflds
          field_ice(ki) = mct_aVect_getRList2c(ki, i2x_a)
          itemc_ice(ki) = trim(field_ice(ki)(scan(field_ice(ki),'_'):))
       enddo
       do ko = 1,noflds
          field_ocn(ko) = mct_aVect_getRList2c(ko, o2x_a)
          itemc_ocn(ko) = trim(field_ocn(ko)(scan(field_ocn(ko),'_'):))
       enddo
       do kx = 1,nxflds
          field_xao(kx) = mct_aVect_getRList2c(kx, xao_a)
          itemc_xao(kx) = trim(field_xao(kx)(scan(field_xao(kx),'_'):))
       enddo

       call mct_aVect_setSharedIndices(l2x_a, x2a_a, l2x_SharedIndices)
       call mct_aVect_setSharedIndices(o2x_a, x2a_a, o2x_SharedIndices)
       call mct_aVect_setSharedIndices(i2x_a, x2a_a, i2x_SharedIndices)
       call mct_aVect_setSharedIndices(z2x_a, x2a_a, z2x_SharedIndices)
       call mct_aVect_setSharedIndices(xao_a, x2a_a, xao_SharedIndices)

       ! Field naming rules
       ! Only atm states that are Sx_... will be merged
       ! Only fluxes that are F??x_... will be merged
       ! All fluxes will be multiplied by corresponding component fraction

       do ka = 1,naflds
          !--- document merge ---
          mrgstr(ka) = subname//'x2a%'//trim(field_atm(ka))//' ='
          if (field_atm(ka)(1:2) == 'PF') then
             cycle ! if flux has first character as P, pass straight through
          end if
          if (field_atm(ka)(1:1) == 'S' .and. field_atm(ka)(2:2) /= 'x') then
             cycle ! any state fields that are not Sx_ will just be copied
          end if

          do kl = 1,nlflds
             if (trim(itemc_atm(ka)) == trim(itemc_lnd(kl))) then
                if ((trim(field_atm(ka)) == trim(field_lnd(kl)))) then
                   if (field_lnd(kl)(1:1) == 'F') lmerge(ka) = .false.
                end if
                ! --- make sure only one field matches ---
                if (lindx(ka) /= 0) then
                   write(logunit,*) subname,' ERROR: found multiple kl field matches for ',trim(itemc_lnd(kl))
                   call shr_sys_abort(subname//' ERROR multiple kl field matches')
                endif
                lindx(ka) = kl
             end if
          end do

          do kz = 1,nzflds
             if (trim(itemc_atm(ka)) == trim(itemc_iac(kz))) then
                if ((trim(field_atm(ka)) == trim(field_iac(kz)))) then
                   if (field_iac(kz)(1:1) == 'F') zmerge(ka) = .false.
                end if
                ! --- make sure only one field matches ---
                if (zindx(ka) /= 0) then
                   write(logunit,*) subname,' ERROR: found multiple kz field matches for ',trim(itemc_iac(kz))
                   call shr_sys_abort(subname//' ERROR multiple kz field matches')
                endif
                zindx(ka) = kz
             end if
          end do

          do ki = 1,niflds
             if (field_ice(ki)(1:1) == 'F' .and. field_ice(ki)(2:4) == 'ioi') then
                cycle ! ignore all fluxes that are ice/ocn fluxes
             end if
             if (trim(itemc_atm(ka)) == trim(itemc_ice(ki))) then
                if ((trim(field_atm(ka)) == trim(field_ice(ki)))) then
                   if (field_ice(ki)(1:1) == 'F') imerge(ka) = .false.
                end if
                ! --- make sure only one field matches ---
                if (iindx(ka) /= 0) then
                   write(logunit,*) subname,' ERROR: found multiple ki field matches for ',trim(itemc_ice(ki))
                   call shr_sys_abort(subname//' ERROR multiple ki field matches')
                endif
                iindx(ka) = ki
             end if
          end do
          do kx = 1,nxflds
             if (trim(itemc_atm(ka)) == trim(itemc_xao(kx))) then
                if ((trim(field_atm(ka)) == trim(field_xao(kx)))) then
                   if (field_xao(kx)(1:1) == 'F') xmerge(ka) = .false.
                end if
                ! --- make sure only one field matches ---
                if (xindx(ka) /= 0) then
                   write(logunit,*) subname,' ERROR: found multiple kx field matches for ',trim(itemc_xao(kx))
                   call shr_sys_abort(subname//' ERROR multiple kx field matches')
                endif
                xindx(ka) = kx
             end if
          end do
          do ko = 1,noflds
             if (trim(itemc_atm(ka)) == trim(itemc_ocn(ko))) then
                if ((trim(field_atm(ka)) == trim(field_ocn(ko)))) then
                   if (field_ocn(ko)(1:1) == 'F') omerge(ka) = .false.
                end if
                ! --- make sure only one field matches ---
                if (oindx(ka) /= 0) then
                   write(logunit,*) subname,' ERROR: found multiple ko field matches for ',trim(itemc_ocn(ko))
                   call shr_sys_abort(subname//' ERROR multiple ko field matches')
                endif
                oindx(ka) = ko
             end if
          end do

          ! --- add some checks ---

          ! --- make sure all terms agree on merge or non-merge aspect ---
          if (oindx(ka) > 0 .and. xindx(ka) > 0) then
             write(logunit,*) subname,' ERROR: oindx and xindx both non-zero, not allowed ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR oindx and xindx both non-zero')
          endif

          ! --- make sure all terms agree on merge or non-merge aspect ---
          if (lindx(ka) > 0 .and. iindx(ka) > 0 .and. (lmerge(ka) .neqv. imerge(ka))) then
             write(logunit,*) subname,' ERROR: lindx and iindx merge logic error ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR lindx and iindx merge logic error')
          endif
          if (lindx(ka) > 0 .and. xindx(ka) > 0 .and. (lmerge(ka) .neqv. xmerge(ka))) then
             write(logunit,*) subname,' ERROR: lindx and xindx merge logic error ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR lindx and xindx merge logic error')
          endif
          if (lindx(ka) > 0 .and. oindx(ka) > 0 .and. (lmerge(ka) .neqv. omerge(ka))) then
             write(logunit,*) subname,' ERROR: lindx and oindx merge logic error ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR lindx and oindx merge logic error')
          endif
          if (xindx(ka) > 0 .and. iindx(ka) > 0 .and. (xmerge(ka) .neqv. imerge(ka))) then
             write(logunit,*) subname,' ERROR: xindx and iindx merge logic error ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR xindx and iindx merge logic error')
          endif
          if (xindx(ka) > 0 .and. oindx(ka) > 0 .and. (xmerge(ka) .neqv. omerge(ka))) then
             write(logunit,*) subname,' ERROR: xindx and oindx merge logic error ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR xindx and oindx merge logic error')
          endif
          if (iindx(ka) > 0 .and. oindx(ka) > 0 .and. (imerge(ka) .neqv. omerge(ka))) then
             write(logunit,*) subname,' ERROR: iindx and oindx merge logic error ',trim(itemc_atm(ka))
             call shr_sys_abort(subname//' ERROR iindx and oindx merge logic error')
          endif

       end do
    end if

    ! Zero attribute vector

    call mct_avect_zero(x2a_a)

    ! Update surface fractions

    kif=mct_aVect_indexRA(fractions_a,"ifrac")
    kof=mct_aVect_indexRA(fractions_a,"ofrac")
    kzf=mct_aVect_indexRA(fractions_a,"zfrac")
    if (samegrid_al) then
    klf=mct_aVect_indexRA(fractions_a,"lfrac")
       fracstr = 'lfrac'
    else
       klf = mct_aVect_indexRA(fractions_a,"lfrin")
       fracstr = 'lfrin'
    endif

    lsize = mct_avect_lsize(x2a_a)

    index_x2a_Sf_lfrac = mct_aVect_indexRA(x2a_a,'Sf_lfrac')
    index_x2a_Sf_ifrac = mct_aVect_indexRA(x2a_a,'Sf_ifrac')
    index_x2a_Sf_ofrac = mct_aVect_indexRA(x2a_a,'Sf_ofrac')
    index_x2a_Sf_zfrac = mct_aVect_indexRA(x2a_a,'Sf_zfrac')
    do n = 1,lsize
       x2a_a%rAttr(index_x2a_Sf_lfrac,n) = fractions_a%Rattr(klf,n)
       x2a_a%rAttr(index_x2a_Sf_ifrac,n) = fractions_a%Rattr(kif,n)
       x2a_a%rAttr(index_x2a_Sf_ofrac,n) = fractions_a%Rattr(kof,n)
       x2a_a%rAttr(index_x2a_Sf_zfrac,n) = fractions_a%Rattr(kzf,n)
    end do

    !--- document fraction operations ---
    if (first_time) then
       mrgstr(index_x2a_sf_lfrac) = trim(mrgstr(index_x2a_sf_lfrac))//' = fractions_a%'//trim(fracstr)
       mrgstr(index_x2a_sf_ifrac) = trim(mrgstr(index_x2a_sf_ifrac))//' = fractions_a%ifrac'
       mrgstr(index_x2a_sf_ofrac) = trim(mrgstr(index_x2a_sf_ofrac))//' = fractions_a%ofrac'
       mrgstr(index_x2a_sf_zfrac) = trim(mrgstr(index_x2a_sf_zfrac))//' = fractions_a%zfrac'
    endif

    ! Copy attributes that do not need to be merged
    ! These are assumed to have the same name in
    ! (o2x_a and x2a_a) and in (l2x_a and x2a_a), etc.

    !--- document copy operations ---
    if (first_time) then
       !--- document merge ---
       do i=1,l2x_SharedIndices%shared_real%num_indices
          i1=l2x_SharedIndices%shared_real%aVindices1(i)
          o1=l2x_SharedIndices%shared_real%aVindices2(i)
          mrgstr(o1) = trim(mrgstr(o1))//' = l2x%'//trim(field_lnd(i1))
       enddo
       do i=1,o2x_SharedIndices%shared_real%num_indices
          i1=o2x_SharedIndices%shared_real%aVindices1(i)
          o1=o2x_SharedIndices%shared_real%aVindices2(i)
          mrgstr(o1) = trim(mrgstr(o1))//' = o2x%'//trim(field_ocn(i1))
       enddo
       do i=1,i2x_SharedIndices%shared_real%num_indices
          i1=i2x_SharedIndices%shared_real%aVindices1(i)
          o1=i2x_SharedIndices%shared_real%aVindices2(i)
          mrgstr(o1) = trim(mrgstr(o1))//' = i2x%'//trim(field_ice(i1))
       enddo
       do i=1,z2x_SharedIndices%shared_real%num_indices
          i1=z2x_SharedIndices%shared_real%aVindices1(i)
          o1=z2x_SharedIndices%shared_real%aVindices2(i)
          mrgstr(o1) = trim(mrgstr(o1))//' = z2x%'//trim(field_iac(i1))
       enddo
       do i=1,xao_SharedIndices%shared_real%num_indices
          i1=xao_SharedIndices%shared_real%aVindices1(i)
          o1=xao_SharedIndices%shared_real%aVindices2(i)
          mrgstr(o1) = trim(mrgstr(o1))//' = xao%'//trim(field_xao(i1))
       enddo
    endif

    !    call mct_aVect_copy(aVin=l2x_a, aVout=x2a_a, vector=mct_usevector)
    !    call mct_aVect_copy(aVin=o2x_a, aVout=x2a_a, vector=mct_usevector)
    !    call mct_aVect_copy(aVin=i2x_a, aVout=x2a_a, vector=mct_usevector)
    !    call mct_aVect_copy(aVin=xao_a, aVout=x2a_a, vector=mct_usevector)
    call mct_aVect_copy(aVin=l2x_a, aVout=x2a_a, vector=mct_usevector, sharedIndices=l2x_SharedIndices)
    call mct_aVect_copy(aVin=o2x_a, aVout=x2a_a, vector=mct_usevector, sharedIndices=o2x_SharedIndices)
    call mct_aVect_copy(aVin=i2x_a, aVout=x2a_a, vector=mct_usevector, sharedIndices=i2x_SharedIndices)
    call mct_aVect_copy(aVin=z2x_a, aVout=x2a_a, vector=mct_usevector, sharedIndices=z2x_SharedIndices)
    call mct_aVect_copy(aVin=xao_a, aVout=x2a_a, vector=mct_usevector, sharedIndices=xao_SharedIndices)

    ! If flux to atm is coming only from the ocean (based on field being in o2x_a) -
    ! -- then scale by both ocean and ice fraction
    ! If flux to atm is coming only from the land or ice or coupler
    ! -- then do scale by fraction above

    do ka = 1,naflds
       !--- document merge ---
       if (first_time) then
          if (lindx(ka) > 0) then
             if (lmerge(ka)) then
                mrgstr(ka) = trim(mrgstr(ka))//' + '//trim(fracstr)//'*l2x%'//trim(field_lnd(lindx(ka)))
             else
                mrgstr(ka) = trim(mrgstr(ka))//' = '//trim(fracstr)//'*l2x%'//trim(field_lnd(lindx(ka)))
             end if
          end if
          if (zindx(ka) > 0) then
             if (zmerge(ka)) then
                mrgstr(ka) = trim(mrgstr(ka))//' + zfrac*z2x%'//trim(field_iac(zindx(ka)))
             else
                mrgstr(ka) = trim(mrgstr(ka))//' = zfrac*z2x%'//trim(field_iac(zindx(ka)))
             end if
          end if
          if (iindx(ka) > 0) then
             if (imerge(ka)) then
                mrgstr(ka) = trim(mrgstr(ka))//' + ifrac*i2x%'//trim(field_ice(iindx(ka)))
             else
                mrgstr(ka) = trim(mrgstr(ka))//' = ifrac*i2x%'//trim(field_ice(iindx(ka)))
             end if
          end if
          if (xindx(ka) > 0) then
             if (xmerge(ka)) then
                mrgstr(ka) = trim(mrgstr(ka))//' + ofrac*xao%'//trim(field_xao(xindx(ka)))
             else
                mrgstr(ka) = trim(mrgstr(ka))//' = ofrac*xao%'//trim(field_xao(xindx(ka)))
             end if
          end if
          if (oindx(ka) > 0) then
             if (omerge(ka)) then
                mrgstr(ka) = trim(mrgstr(ka))//' + ofrac*o2x%'//trim(field_ocn(oindx(ka)))
             end if
             if (.not. omerge(ka)) then
                mrgstr(ka) = trim(mrgstr(ka))//' + (ifrac+ofrac)*o2x%'//trim(field_ocn(oindx(ka)))
             end if
          end if
       endif

       do n = 1,lsize
          fracl = fractions_a%Rattr(klf,n)
          fraci = fractions_a%Rattr(kif,n)
          fraco = fractions_a%Rattr(kof,n)
          fracz = fractions_a%Rattr(kzf,n)
          if (lindx(ka) > 0 .and. fracl > 0._r8) then
             if (lmerge(ka)) then
                x2a_a%rAttr(ka,n) = x2a_a%rAttr(ka,n) + l2x_a%rAttr(lindx(ka),n) * fracl
             else
                x2a_a%rAttr(ka,n) = l2x_a%rAttr(lindx(ka),n) * fracl
             end if
          end if
          if (zindx(ka) > 0 .and. fracz > 0._r8) then
             if (zmerge(ka)) then
                x2a_a%rAttr(ka,n) = x2a_a%rAttr(ka,n) + z2x_a%rAttr(zindx(ka),n) * fracz
             else
                x2a_a%rAttr(ka,n) = z2x_a%rAttr(zindx(ka),n) * fracz
             end if
          end if
          if (iindx(ka) > 0 .and. fraci > 0._r8) then
             if (imerge(ka)) then
                x2a_a%rAttr(ka,n) = x2a_a%rAttr(ka,n) + i2x_a%rAttr(iindx(ka),n) * fraci
             else
                x2a_a%rAttr(ka,n) = i2x_a%rAttr(iindx(ka),n) * fraci
             end if
          end if
          if (xindx(ka) > 0 .and. fraco > 0._r8) then
             if (xmerge(ka)) then
                x2a_a%rAttr(ka,n) = x2a_a%rAttr(ka,n) + xao_a%rAttr(xindx(ka),n) * fraco
             else
                x2a_a%rAttr(ka,n) = xao_a%rAttr(xindx(ka),n) * fraco
             end if
          end if
          if (oindx(ka) > 0) then
             if (omerge(ka) .and. fraco > 0._r8) then
                x2a_a%rAttr(ka,n) = x2a_a%rAttr(ka,n) + o2x_a%rAttr(oindx(ka),n) * fraco
             end if
             if (.not. omerge(ka)) then
                !--- NOTE: This IS using the ocean fields and ice fraction !! ---
                x2a_a%rAttr(ka,n) = o2x_a%rAttr(oindx(ka),n) * fraci
                x2a_a%rAttr(ka,n) = x2a_a%rAttr(ka,n) + o2x_a%rAttr(oindx(ka),n) * fraco
             end if
          end if
       end do
    end do

    if (first_time) then
       if (iamroot) then
          write(logunit,'(A)') subname//' Summary:'
          do ka = 1,naflds
             write(logunit,'(A)') trim(mrgstr(ka))
          enddo
       endif
       deallocate(mrgstr)
       deallocate(field_atm,itemc_atm)
       deallocate(field_lnd,itemc_lnd)
       deallocate(field_ice,itemc_ice)
       deallocate(field_iac,itemc_iac)
       deallocate(field_ocn,itemc_ocn)
       deallocate(field_xao,itemc_xao)
    endif

    first_time = .false.

  end subroutine prep_atm_merge

  !================================================================================================

  subroutine prep_atm_calc_o2x_ax(fractions_ox, timer)
    !---------------------------------------------------------------
    ! Description
    ! Create o2x_ax (note that o2x_ax is a local module variable)
    !
    ! Arguments
    type(mct_aVect) , optional, intent(in) :: fractions_ox(:)
    character(len=*), optional, intent(in) :: timer
    !
    ! Local Variables
    integer :: eoi, efi, emi
    type(mct_aVect) , pointer :: o2x_ox
    character(*), parameter   :: subname = '(prep_atm_calc_o2x_ax)'
    character(*), parameter   :: F00 = "('"//subname//" : ', 4A )"
    !---------------------------------------------------------------

    call t_drvstartf (trim(timer),barrier=mpicom_CPLID)
    do emi = 1,num_inst_max
       eoi = mod((emi-1),num_inst_ocn) + 1
       efi = mod((emi-1),num_inst_frc) + 1

       o2x_ox => component_get_c2x_cx(ocn(eoi))
       if (present(fractions_ox)) then
          call seq_map_map(mapper_So2a, o2x_ox, o2x_ax(emi),&
               fldlist=seq_flds_o2x_states,norm=.true., &
               avwts_s=fractions_ox(efi),avwtsfld_s='ofrac')
       else
          call seq_map_map(mapper_So2a, o2x_ox, o2x_ax(emi),&
               fldlist=seq_flds_o2x_states,norm=.true.)
       endif
       call seq_map_map(mapper_Fo2a, o2x_ox, o2x_ax(emi),&
            fldlist=seq_flds_o2x_fluxes,norm=.true.)
    enddo
    call t_drvstopf  (trim(timer))

  end subroutine prep_atm_calc_o2x_ax

  !================================================================================================

  subroutine prep_atm_calc_i2x_ax(fractions_ix, timer)
    !---------------------------------------------------------------
    ! Description
    ! Create i2x_ax (note that i2x_ax is a local module variable)
    !
    ! Arguments
    type(mct_aVect) , intent(in) :: fractions_ix(:)
    character(len=*), intent(in) :: timer
    !
    ! Local Variables
    integer :: eii, efi
    type(mct_aVect) , pointer :: i2x_ix
    character(*), parameter   :: subname = '(prep_atm_calc_i2x_ax)'
    character(*), parameter   :: F00 = "('"//subname//" : ', 4A )"
    !---------------------------------------------------------------

    call t_drvstartf (trim(timer),barrier=mpicom_CPLID)
    do eii = 1,num_inst_ice
       efi = mod((eii-1),num_inst_frc) + 1

       i2x_ix => component_get_c2x_cx(ice(eii))
       call seq_map_map(mapper_Si2a, i2x_ix, i2x_ax(eii), &
            fldlist=seq_flds_i2x_states, &
            avwts_s=fractions_ix(eii), avwtsfld_s='ifrac')
       call seq_map_map(mapper_Fi2a, i2x_ix, i2x_ax(eii), &
            fldlist=seq_flds_i2x_fluxes, &
            avwts_s=fractions_ix(eii), avwtsfld_s='ifrac')
    enddo
    call t_drvstopf  (trim(timer))

  end subroutine prep_atm_calc_i2x_ax

  !================================================================================================

  subroutine prep_atm_calc_l2x_ax(fractions_lx, timer)
    !---------------------------------------------------------------
    ! Description
    ! Create l2x_ax (note that l2x_ax is a local module variable)
    !
    ! Arguments
    type(mct_aVect) , intent(in) :: fractions_lx(:)
    character(len=*), intent(in) :: timer
    !
    ! Local Variables
    integer :: eli, efi
    type(mct_avect), pointer :: l2x_lx
    character(*), parameter  :: subname = '(prep_atm_calc_l2x_ax)'
    character(*), parameter  :: F00 = "('"//subname//" : ', 4A )"
    !---------------------------------------------------------------

    call t_drvstartf (trim(timer),barrier=mpicom_CPLID)
    do eli = 1,num_inst_lnd
       efi = mod((eli-1),num_inst_frc) + 1

       l2x_lx => component_get_c2x_cx(lnd(eli))
       call seq_map_map(mapper_Sl2a, l2x_lx, l2x_ax(eli), &
            fldlist=seq_flds_l2x_states, norm=.true., &
            avwts_s=fractions_lx(efi), avwtsfld_s='lfrin')
       call seq_map_map(mapper_Fl2a, l2x_lx, l2x_ax(eli), &
            fldlist=seq_flds_l2x_fluxes, norm=.true., &
            avwts_s=fractions_lx(efi), avwtsfld_s='lfrin')
    enddo
    call t_drvstopf  (trim(timer))

  end subroutine prep_atm_calc_l2x_ax

  !================================================================================================

  subroutine prep_atm_calc_z2x_ax(fractions_zx, timer)
    !---------------------------------------------------------------
    ! Description
    ! Create z2x_ax (note that z2x_ax is a local module variable)
    !
    ! Arguments
    type(mct_aVect) , intent(in) :: fractions_zx(:)
    character(len=*), intent(in) :: timer
    !
    ! Local Variables
    integer :: ezi, efi
    type(mct_avect), pointer :: z2x_zx
    character(*), parameter  :: subname = '(prep_atm_calc_z2x_ax)'
    character(*), parameter  :: F00 = "('"//subname//" : ', 4A )"
    !---------------------------------------------------------------

    call t_drvstartf (trim(timer),barrier=mpicom_CPLID)
    do ezi = 1,num_inst_iac
       efi = mod((ezi-1),num_inst_frc) + 1

       z2x_zx => component_get_c2x_cx(iac(ezi))
       call seq_map_map(mapper_Fz2a, z2x_zx, z2x_ax(ezi), &
            fldlist=seq_flds_z2x_fluxes, norm=.true., &
            avwts_s=fractions_zx(efi), avwtsfld_s='zfrac')
    enddo
    call t_drvstopf  (trim(timer))

  end subroutine prep_atm_calc_z2x_ax

  !================================================================================================

  function prep_atm_get_l2x_ax()
    type(mct_aVect), pointer :: prep_atm_get_l2x_ax(:)
    prep_atm_get_l2x_ax => l2x_ax(:)
  end function prep_atm_get_l2x_ax

  function prep_atm_get_i2x_ax()
    type(mct_aVect), pointer :: prep_atm_get_i2x_ax(:)
    prep_atm_get_i2x_ax => i2x_ax(:)
  end function prep_atm_get_i2x_ax

  function prep_atm_get_o2x_ax()
    type(mct_aVect), pointer :: prep_atm_get_o2x_ax(:)
    prep_atm_get_o2x_ax => o2x_ax(:)
  end function prep_atm_get_o2x_ax

  function prep_atm_get_z2x_ax()
    type(mct_aVect), pointer :: prep_atm_get_z2x_ax(:)
    prep_atm_get_z2x_ax => z2x_ax(:)
  end function prep_atm_get_z2x_ax

  function prep_atm_get_mapper_So2a()
    type(seq_map), pointer :: prep_atm_get_mapper_So2a
    prep_atm_get_mapper_So2a => mapper_So2a
  end function prep_atm_get_mapper_So2a

  function prep_atm_get_mapper_Fo2a()
    type(seq_map), pointer :: prep_atm_get_mapper_Fo2a
    prep_atm_get_mapper_Fo2a => mapper_Fo2a
  end function prep_atm_get_mapper_Fo2a

  function prep_atm_get_mapper_Sl2a()
    type(seq_map), pointer :: prep_atm_get_mapper_Sl2a
    prep_atm_get_mapper_Sl2a => mapper_Sl2a
  end function prep_atm_get_mapper_Sl2a

  function prep_atm_get_mapper_Fl2a()
    type(seq_map), pointer :: prep_atm_get_mapper_Fl2a
    prep_atm_get_mapper_Fl2a => mapper_Fl2a
  end function prep_atm_get_mapper_Fl2a

  function prep_atm_get_mapper_Si2a()
    type(seq_map), pointer :: prep_atm_get_mapper_Si2a
    prep_atm_get_mapper_Si2a => mapper_Si2a
  end function prep_atm_get_mapper_Si2a

  function prep_atm_get_mapper_Fi2a()
    type(seq_map), pointer :: prep_atm_get_mapper_Fi2a
    prep_atm_get_mapper_Fi2a => mapper_Fi2a
  end function prep_atm_get_mapper_Fi2a

  function prep_atm_get_mapper_Fz2a()
    type(seq_map), pointer :: prep_atm_get_mapper_Fz2a
    prep_atm_get_mapper_Fz2a => mapper_Fz2a
  end function prep_atm_get_mapper_Fz2a

  !================================================================================================

end module prep_atm_mod
