! md_chain_mts_lj.f90
! Molecular dynamics, multiple timesteps, chain molecule
PROGRAM md_chain_mts_lj

  USE, INTRINSIC :: iso_fortran_env, ONLY : input_unit, output_unit, error_unit, iostat_end, iostat_eor

  USE config_io_module, ONLY : read_cnf_atoms, write_cnf_atoms
  USE averages_module,  ONLY : time_stamp, run_begin, run_end, blk_begin, blk_end, blk_add
  USE md_module,        ONLY : model_description, allocate_arrays, deallocate_arrays, &
       &                       force, r, v, f, f_spring, n, spring, worst_bond
  IMPLICIT NONE

  ! Takes in a configuration of atoms in a linear chain (positions, velocities)
  ! NO periodic boundary conditions, no box
  ! Conducts molecular dynamics with springs and multiple timesteps
  ! Uses no special neighbour lists

  ! Reads several variables and options from standard input using a namelist nml
  ! Leave namelist empty to accept supplied defaults

  ! Input configuration, output configuration, all calculations, and all results 
  ! are given in mass = 1 units, and in simulation units defined by the model 
  ! For example, for Lennard-Jones, sigma = 1, epsilon = 1

  ! Despite the program name, there is nothing here specific to Lennard-Jones
  ! The model is defined in md_module

  ! Most important variables
  INTEGER :: n_mts      ! number of small steps per large step
  REAL    :: dt         ! time step (smallest)
  REAL    :: bond       ! bond length
  REAL    :: k_spring   ! bond spring constant
  REAL    :: pot        ! total LJ potential energy
  REAL    :: pot_spring ! total spring potential energy
  REAL    :: kin        ! total kinetic energy
  REAL    :: temp_kinet ! kinetic temperature (LJ sigma=1 units, to be averaged)
  REAL    :: energy     ! total energy per atom (LJ sigma=1 units, to be averaged)

  INTEGER :: blk, stp, nstep, nblock, stp_mts, ioerr

  CHARACTER(len=4), PARAMETER :: cnf_prefix = 'cnf.'
  CHARACTER(len=3), PARAMETER :: inp_tag = 'inp', out_tag = 'out'
  CHARACTER(len=3)            :: sav_tag = 'sav' ! may be overwritten with block number

  NAMELIST /nml/ nblock, nstep, dt, k_spring, n_mts

  WRITE ( unit=output_unit, fmt='(a)' ) 'md_chain_mts_lj'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Molecular dynamics, constant-NVE ensemble, chain molecule, multiple time steps'
  WRITE ( unit=output_unit, fmt='(a)' ) 'Particle mass=1 throughout'
  CALL model_description ( output_unit )
  CALL time_stamp ( output_unit )

  ! Set sensible default run parameters for testing
  nblock   = 10
  nstep    = 1000
  dt       = 0.0002
  k_spring = 10000.0
  n_mts    = 10

  READ ( unit=input_unit, nml=nml, iostat=ioerr )
  IF ( ioerr /= 0 ) THEN
     WRITE ( unit=error_unit, fmt='(a,i15)') 'Error reading namelist nml from standard input', ioerr
     IF ( ioerr == iostat_eor ) WRITE ( unit=error_unit, fmt='(a)') 'End of record'
     IF ( ioerr == iostat_end ) WRITE ( unit=error_unit, fmt='(a)') 'End of file'
     STOP 'Error in md_chain_mts_lj'
  END IF
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of blocks',          nblock
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of steps per block', nstep
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Time step',                 dt
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Bond spring constant',      k_spring
  WRITE ( unit=output_unit, fmt='(a,t40,i15  )' ) 'Multiple time step factor', n_mts
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Large time step',           dt*n_mts

  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, bond ) ! First call is just to get n and bond
  WRITE ( unit=output_unit, fmt='(a,t40,i15)'   ) 'Number of particles',          n
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Bond length (in sigma units)', bond

  CALL allocate_arrays

  CALL read_cnf_atoms ( cnf_prefix//inp_tag, n, bond, r, v ) ! Second call is to get r and v
  WRITE ( unit=output_unit, fmt='(a,t40,es15.5)' ) 'Worst bond length deviation = ', worst_bond ( bond )

  CALL force ( pot )
  CALL spring ( k_spring, bond, pot_spring )
  kin        = 0.5*SUM(v**2)
  energy     = ( pot + pot_spring + kin ) / REAL ( n )
  temp_kinet = 2.0 * kin / REAL ( 3*(n-1) ) 
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Initial total energy', energy
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)' ) 'Initial temp-kinet',   temp_kinet

  CALL run_begin ( [ CHARACTER(len=15) :: 'Energy', 'Temp-Kinet' ] )

  DO blk = 1, nblock ! Begin loop over blocks

     CALL blk_begin

     DO stp = 1, nstep ! Begin loop over steps

        ! Single time step of length n_mts*dt
        v = v + 0.5 * REAL(n_mts) * dt * f  ! Kick half-step

        DO stp_mts = 1, n_mts ! loop over n_mts steps of length dt
           v = v + 0.5 * dt * f_spring                ! Kick half-step (small)
           r = r + dt * v                             ! Drift step (small)
           CALL spring ( k_spring, bond, pot_spring ) ! Spring force evaluation
           v = v + 0.5 * dt * f_spring                ! Kick half-step (small)
        END DO ! end loop over n_mts steps of length dt

        CALL force ( pot )   ! Non-bonded force evaluation
        v = v + 0.5 * REAL(n_mts) * dt * f ! Kick half-step
        ! End single time step of length n_mts*dt

        kin        = 0.5*SUM(v**2)
        energy     = ( pot + pot_spring + kin ) / REAL ( n )
        temp_kinet = 2.0 * kin / REAL ( 3*(n-1) )

        ! Calculate all variables for this step
        CALL blk_add ( [energy,temp_kinet] )

     END DO ! End loop over steps

     CALL blk_end ( blk, output_unit )
     IF ( nblock < 1000 ) WRITE(sav_tag,'(i3.3)') blk            ! number configuration by block
     CALL write_cnf_atoms ( cnf_prefix//sav_tag, n, bond, r, v ) ! save configuration

  END DO ! End loop over blocks

  CALL run_end ( output_unit )

  CALL force ( pot )
  CALL spring ( k_spring, bond, pot_spring )
  kin         = 0.5*SUM(v**2)
  energy      = ( pot + pot_spring + kin ) / REAL ( n )
  temp_kinet = 2.0 * kin / REAL ( 3*(n-1) )
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)'  ) 'Final total energy',             energy
  WRITE ( unit=output_unit, fmt='(a,t40,f15.5)'  ) 'Final temp-kinet',               temp_kinet
  WRITE ( unit=output_unit, fmt='(a,t40,es15.5)' ) 'Worst bond length deviation = ', worst_bond ( bond )
  CALL time_stamp ( output_unit )

  CALL write_cnf_atoms ( cnf_prefix//out_tag, n, bond, r, v )

  CALL deallocate_arrays

END PROGRAM md_chain_mts_lj

