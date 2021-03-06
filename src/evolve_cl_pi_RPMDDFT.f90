subroutine evolve_cl_pi_RPMDDFT(p,r,v,vew,vlj,vint,dvdr,dvdr2,dt,mass,na,nb, &
                     boxlxyz,z,beta,vir,vir_lf,irun,nbaro)
  use thermostat
  use barostat
  use gle
  implicit none
  include 'globals.inc'
#ifdef PARALLEL_BINDING
  include 'mpif.h' !parallel
#endif
  ! ------------------------------------------------------------------
  ! RPMD / RPMDFT evolution
  ! 
  ! ------------------------------------------------------------------
  integer na,nb,irun,k,j,i,nbdf1,nbdf2,im,ic,mts,nbaro,rpmddft,nbdf3,ierr,myid
  real(8) p(3,na,nb),r(3,na,nb),dvdr(3,na,nb),dvdr2(3,na,nb),dvdre(3,na,nb),dvdrl(3,na,nb)
  real(8) mass(na),z(na),boxlxyz(3)
  real(8) vir(3,3),vir_lj(3,3),vir_ew(3,3),tvxyz(3),tvxyz_itr(3)
  real(8) vir_itr(3,3),vir_ewc(3,3),vir_lf(3,3),vir_hf(3,3),virMM(3,3),virCP2K(3,3),virMMh(3,3),virMMl(3,3)
  real(8) pprime,halfdtsmall,halfdt,om,gaussian
  real(8) dt,v,beta,dtsmall,vew,vlj,vint,sig,ve,vCP2K,vMM,vMMh,vMMl
  real(8) tv,tv_itr,tq1,tq2,c1,c2,c3
  real(8) dheat, comx, comy, comz, mm !!GLE
  character(len=4) type
  external gaussian
  common /path_i/ om,type
  common /beaddiabatic/ nbdf1,nbdf2
  common /multiple_ts/ mts
  common /correct/ sig
  common /RPMDDFT/ rpmddft,nbdf3
  real(8) rnm(3,na,nb),rb(3,na,nbdf3),dvdrCP2K(3,na,nbdf3),dvdrMM(3,na,nbdf3)
  real(8) dvdrb(3,na,nbdf3),dvdrMMl(3,na,nbdf3),dvdrMMh(3,na,nbdf3),dvdrdelta(3,na,nb),dvdrdelta2(3,na,nbdf3)


  ! Zero constants and arrays
  dvdrl(:,:,:) = 0.d0
  dvdre(:,:,:) = 0.d0
  dvdrMM(:,:,:) = 0.d0
  dvdrMMh(:,:,:) = 0.d0
  dvdrMMl(:,:,:) = 0.d0
  dvdrCP2K(:,:,:) = 0.d0
  dvdrb(:,:,:) = 0.d0
  dvdrdelta(:,:,:) = 0.d0
  rnm(:,:,:) = 0.d0
  rb(:,:,:) = 0.d0
  vCP2K = 0.d0
  vMM = 0.d0
  vMMh = 0.d0
  vMMl = 0.d0
  vew = 0.d0
  vlj = 0.d0
  vint = 0.d0
  vir_itr(:,:) = 0.d0
  vir_lj(:,:) = 0.d0
  vir_ew(:,:) = 0.d0
  vir_hf(:,:) = 0.d0
  virCP2K(:,:) = 0.d0
  virMM(:,:) = 0.d0
	virMMh(:,:) = 0.d0
	virMMl(:,:) = 0.d0
  tv = 0.d0
  tvxyz(:) = 0.d0

  halfdt = 0.5d0*dt

#ifdef PARALLEL_BINDING
	call MPI_COMM_RANK( MPI_COMM_WORLD, myid, ierr)
!write(*,*) "myid iin evolve_cl_pi:",myid
#endif

#ifdef PARALLEL_BINDING
if(myid.eq.0) then     
#endif         
  if (type.eq.'RPMD') then
     if (therm.eq.'PRG') then
        call parinello_therm(p,mass,ttau,na,nb,halfdt,irun,beta)
     else if (therm.eq.'PRL') then
        call parinello_therm_loc(p,mass,ttau,na,nb, &
                                 dt,irun,beta)
     else if (therm.eq.'GLE') then     !! GLE
         call therm_gle(p,dheat,mass,na,nb,irun)
     endif
  endif

  p(:,:,:) = p(:,:,:) - halfdt*(dvdr(:,:,:)+dvdr2(:,:,:)) !hier sind alle Kräfte drin!

  !  get new coordinates
     if (type.eq.'ACMD') then
        call freerp_acmd (p,r,dt,mass,na,nb,beta,irun,om)
     else if (type.eq.'RPMD') then
        call freerp_rpmd (p,r,dt,mass,na,nb,beta)
     endif

  ! Form Bead Positions and evaluate high-frequency forces
  call forces(r,vint,dvdr2,nb,na,boxlxyz,z,vir_hf,4)

  p(:,:,:) = p(:,:,:) - halfdt*dvdr2(:,:,:)
     


   vir(:,:) = vir_lf(:,:) + vir_hf(:,:)   
  ! Barostat
  ! (note:// COMs scaled therefore do not need to recalculate
  !  intramolecular forces as they remain the same)

  if (nbaro.eq.1) then
     if (baro.eq.'BER') then
				call virial_ke(r,dvdr,dvdr2,tv,tvxyz,tq1,tq2,beta,na,nb,mass)
        call beren_driver(vir,tv,tvxyz,dt,r,boxlxyz,na,nb)
     else if (baro.eq.'MCI') then
        call mc_baro(r,dvdr,dvdr2,vir,v,z,beta,boxlxyz,na,nb,irun)
     else 
        write(6,*) ' ** Invalid barostat **'
        stop
     endif
  endif





  ! Evaluation of the low frequency forces using RP-contraction
  ! --------------------------------------------------------------

  ! Convert the positions to the normal mode representation
  rnm(:,:,:) = r(:,:,:)
  call realft (rnm,3*na,nb,+1)

  ! Ewald

  if (nbdf1.gt.0) then
     call rp_contract_nm(rnm,vew,dvdr,nb,na,boxlxyz,z,vir_ew, &
                         nbdf1,2)
     if (sig.gt.0.d0) then

        ! Short range coulombic correction

        call rp_contract_nm(rnm,ve,dvdre,nb,na,boxlxyz,z, &
                             vir_ewc,nbdf1,5)
        vew = vew - ve
        vir_ew(:,:) = vir_ew(:,:) - vir_ewc(:,:)
        dvdr(:,:,:) = dvdr(:,:,:) - dvdre(:,:,:)
     endif
  endif

  ! LJ

  if (nbdf2.gt.0) then
     call rp_contract_nm(rnm,vlj,dvdrl,nb,na,boxlxyz,z,vir_lj, &
                          nbdf2,3)
  endif

  !!! Convert the positions and mometa back to the bead
  !!! representation 

  !!!call realft (r,3*na,nb,-1) hier müsstae dann rnm stehen

  ! Transform dvdr back to bead representation (if needed)

  if ((nbdf1.gt.0).and.(nbdf2.gt.0)) then
     dvdr(:,:,:) = dvdr(:,:,:) + dvdrl(:,:,:)
     call realft(dvdr,3*na,nb,-1)
  else
     if (nbdf1.gt.0) then
        call realft(dvdr,3*na,nb,-1)
     else if (nbdf2.gt.0) then
        call realft(dvdrl,3*na,nb,-1)
     endif
  endif

  ! Evaluate non beadd forces

  if (nbdf1.le.0) then
     call forces(r,vew,dvdr,nb,na,boxlxyz,z,vir_ew,2)
  else if (sig.gt.0.d0) then

     ! Short range coulombic correction

     call forces(r,ve,dvdre,nb,na,boxlxyz,z,vir_ewc,5)

     vew = vew + ve
     vir_ew(:,:) = vir_ew(:,:) + vir_ewc(:,:)
     dvdr(:,:,:) = dvdr(:,:,:) + dvdre(:,:,:)
  endif

  if (nbdf2.le.0) then
     call forces(r,vlj,dvdrl,nb,na,boxlxyz,z,vir_lj,3)
  endif

  ! Sum ewald and LJ forces if needed

  if ((nbdf1.le.0).or.(nbdf2.le.0)) then
     dvdr(:,:,:) = dvdr(:,:,:) + dvdrl(:,:,:)
  endif


#ifdef PARALLEL_BINDING
endif
	call MPI_bcast(dvdr,SIZE(dvdr),MPI_real8,0,MPI_COMM_WORLD,ierr)
	call MPI_bcast(dvdr2,SIZE(dvdr2),MPI_real8,0,MPI_COMM_WORLD,ierr)
	call MPI_bcast(vir,SIZE(vir),MPI_real8,0,MPI_COMM_WORLD,ierr)
#endif

  ! Evaluate CP2K and MM, nb=nbdf3 force:
  if (nbdf3.eq.0) then 
    write(6,*) '* nbdf3 has to be nonzero if cl_pi is used'
    stop
  else

  ! Form contracted RP coordinates
#ifdef PARALLEL_BINDING
		if(myid.eq.0) then
#endif
    call ring_contract(rnm,rb,na,nb,nbdf3)
#ifdef PARALLEL_BINDING
		endif
		call MPI_bcast(rb,SIZE(rb),MPI_real8,0,MPI_COMM_WORLD,ierr)
#endif
  ! Evaluate forces on the bead coordinates rb
	
    call forces(rb,vCP2K,dvdrCP2K,nbdf3,na,boxlxyz,z,virCP2K,9)
#ifdef PARALLEL_BINDING
		if(myid.eq.0) then
#endif    
    !call forces(rb,vMM,dvdrb,nbdf3,na,boxlxyz,z,virMM,0) !PRoblem, das bei full forces hier RPMDDFT_forece aufgerufen wird, da rpmddft =1
		call forces(rb,vMMl,dvdrMMl,nbdf3,na,boxlxyz,z,virMMl,1)
		call forces(rb,vMMh,dvdrMMh,nbdf3,na,boxlxyz,z,virMMh,4)
		dvdrMM(:,:,:) = dvdrMMl(:,:,:)+dvdrMMh(:,:,:)
		virMM(:,:) = virMMl(:,:) + virMMh(:,:)
		vMM = vMMl + vMMh
		dvdrdelta2(:,:,:) = dvdrCP2K(:,:,:)-dvdrMM(:,:,:)

	call force_contract(dvdrdelta,dvdrdelta2,na,nb,nbdf3)
#ifdef PARALLEL_BINDING
		endif
#endif    
  endif
#ifdef PARALLEL_BINDING
		if(myid.eq.0) then
#endif
  ! Convert dvdrdelta back to bead representation
  call realft(dvdrdelta,3*na,nb,-1)
  


	!write(*,*) "dvdr:", dvdr(:,1,3)
	!write(*,*) "dvdrCP2K:", dvdrCP2K(:,1,3)
	!write(*,*) "dvdrMM:", dvdrMM(:,1,3)
	!write(*,*) "dvdrCP2K-dvdrMM", dvdrCP2K(:,1,3)-dvdrMM(:,1,3)
	!write(*,*) "dvdr+dvdrCP2K-dvdrMM", dvdr(:,1,3)+dvdrCP2K(:,1,3)-dvdrMM(:,1,3)
	dvdr(:,:,:) = dvdr(:,:,:)+dvdrdelta(:,:,:)
  ! Evolve the momenta under the low+CP2K+MM forces

  p(:,:,:) = p(:,:,:) - halfdt*dvdr(:,:,:)


  
  if (type.eq.'RPMD') then
     if (therm.eq.'PRG') then
        call parinello_therm(p,mass,ttau,na,nb,halfdt,irun,beta)
     else if (therm.eq.'PRL') then
        call parinello_therm_loc(p,mass,ttau,na,nb, &
                                       dt,irun,beta)
     else if (therm.eq.'GLE') then     !! GLE
         call therm_gle(p,dheat,mass,na,nb,irun)
     endif
  endif

  ! Potential Energy

  v = vew + vlj + vint - vMM + vCP2K ! ??????????????????

  ! Virial

  vir_lf(:,:) = vir_lj(:,:) + vir_ew(:,:)+ virCP2K(:,:) - virMM(:,:)    !????
  vir(:,:) =  vir_lf(:,:) + vir_hf(:,:)  


  !compute COM and outputs to make sure that we removed COM velocity correctly....
  comx=0.d0
  comy=0.d0
  comz=0.d0
  mm=0.0d0
  do j = 1,na
    do k = 1,nb
      comx=comx+mass(j)*r(1,j,k)
      comy=comy+mass(j)*r(2,j,k)
      comz=comz+mass(j)*r(3,j,k)
    enddo
    mm=mm+mass(j)
  enddo
  comx=comx/mm
  comy=comy/mm
  comz=comz/mm
!  write(*,*) "COM: ",comx,comy,comz
#ifdef PARALLEL_BINDING
endif
#endif
  return
end subroutine evolve_cl_pi_RPMDDFT
