# if IMKL
    Include 'mkl_vsl.f90'  !Include allows use of Intel MKL random number generators
    !The Intel MKL is only portable to IA32 and IA64 -like architectures...
    !ARM processors cannot use the IMKL libraries, and so default to the intrinsic RNG.
# endif
    
Module Random_Numbers
    
    Use Kinds, Only: dp
    Use Kinds, Only: id
#   if IMKL
        Use MKL_VSL_TYPE, Only: VSL_STREAM_STATE
#   else
        Use PRNGs, Only: MT19937_Type
#   endif
    Implicit None
    Private
    Public :: RNG_Type
    Public :: Setup_RNG
    
    Type :: RNG_Type
#       if IMKL
            Type(VSL_STREAM_STATE) :: stream  !stream state variable for RNG
#       else
            Type(MT19937_Type) :: stream
            Logical :: RNG_by_Stream_Files
#       endif
        Real(dp), Allocatable :: q(:)  !Pre-filled array of random numbers generated by stream
        Integer :: q_size  !size of array q
        Integer :: q_index  !position of next random number to be used in q
        Integer :: seed  !value used to seed the RNG
        Integer(id) :: q_refreshed  !number of times the random array has been filled
        ! Number of random numbers used is q_size*(q_refreshed - 1) + q_index - 1
    Contains
        Procedure, Pass :: Get_Random => Get_1_Random
        Procedure, Pass :: Get_Randoms => Get_n_Randoms
        !Procedure, Pass :: Restart => Restart_RNG
        Procedure, Pass :: Initialize => Initialize_RNG
        Procedure, Pass :: Cleanup => Cleanup_RNG
        Procedure, Pass :: Save_RNG
        Procedure, Pass :: Load_RNG
    End Type
    
    !N2H Improve detail of RNG stat checking to include detailed error trapping rather than general stops in current implementation

Contains
    
Function Setup_RNG(setup_file_name,run_file_name) Result(RNG)
    Use FileIO_Utilities, Only: Worker_Index
    Use FileIO_Utilities, Only: n_Workers
    Use FileIO_Utilities, Only: Output_Message
    Implicit None
    Type(RNG_Type) :: RNG
    Character(*), Intent(In) :: setup_file_name  !file to read for RNG seeding
    Character(*), Intent(In) :: run_file_name  !file to write copy of RNG setup information
    Logical :: RNG_seed_random  !flag indicationg whether the RNG should be started using a random or specific seed
    Integer :: RNG_seed  !specific seed to start RNG
    Integer :: t  !thread or image number, used to start independent RNGs for parallel execution
    Integer :: setup_unit,stat
    
    NameList /RNGSetupList/ RNG_seed_random,RNG_seed
    
    !open setup file and read namelist
    Open(NEWUNIT = setup_unit , FILE = setup_file_name , STATUS = 'OLD' , ACTION = 'READ' , IOSTAT = stat)
    If (stat .NE. 0) Call Output_Message('ERROR:  Random_Numbers: Setup_RNG:  File open error, '//setup_file_name//', IOSTAT=',stat,kill=.TRUE.)
    Read(setup_unit,NML = RNGSetupList)
    Close(setup_unit)
    If (RNG_seed_random) Then  !use current clock time as seed
        Call SYSTEM_CLOCK(RNG_seed)
        RNG_seed_random = .TRUE.
    End If
    t = Worker_Index()
    If (n_Workers() .GT. 1) Then !setup is being called from inside a parallel region
        Call RNG%Initialize(seed = RNG_seed , thread = t-1)
    Else  !initialize for serial execution
        Call RNG%Initialize(seed = RNG_seed)
    End If
    If (t .EQ. 1) Then
        Open(NEWUNIT = setup_unit , FILE = run_file_name , STATUS = 'OLD' , ACTION = 'WRITE' , POSITION = 'APPEND' , IOSTAT = stat)
        If (stat .NE. 0) Call Output_Message('ERROR:  Random_Numbers: Setup_RNG:  File open error, '//run_file_name//', IOSTAT=',stat,kill=.TRUE.)
        Write(setup_unit,NML = RNGSetupList)
        Write(setup_unit,*)
        Close(setup_unit)
    End If
End Function Setup_RNG

Subroutine Initialize_RNG(RNG,seed,thread,size)  !Initializes a RNG and returns state variables for that stream
#   if IMKL
        Use MKL_VSL, Only: vslnewstream,VSL_BRNG_MT2203,VSL_BRNG_SFMT19937
        Use MKL_VSL, Only: VSL_ERROR_OK,VSL_STATUS_OK
        Use MKL_VSL, Only: vdrnguniform,VSL_RNG_METHOD_UNIFORM_STD
#   endif
    Use Kinds, Only: dp
    Use FileIO_Utilities, Only: Output_Message
    Implicit None
    Class(RNG_Type),Intent(Out) :: RNG
    Integer, Intent(In), Optional :: seed  !RNG seed to initialize RNG stream, omission indicates a random seed
    Integer, Intent(In), Optional :: thread  !index of calling thread, omission indicates serial execution
    Integer, Intent(In), Optional :: size  !size of random number array to pre-fill, default 2**12
#   if IMKL
        Integer :: rng_stat  !status returns from MKL RNG operations
#   else
        Integer :: i
#   endif
    
    If (Present(size)) Then
        RNG%q_size = size
    Else
        RNG%q_size = 2**12
    End If
    Allocate(RNG%q(1:RNG%q_size))
    If (Present(seed)) Then
        RNG%seed = seed
    Else  !Generate a random seed (date-and-time based)
        Call SYSTEM_CLOCK(RNG%seed)  !sets seed to a value between [0,Huge) based on current date and time
    End If
#   if IMKL
        If (Present(thread)) Then  !Parallel execution, use an independent MT2203 stream for each thread
            rng_stat = vslnewstream(RNG%stream,VSL_BRNG_MT2203+thread,RNG%seed)
        Else  !serial execution, use SIMD-oriented fast MT19937
            rng_stat = vslnewstream(RNG%stream,VSL_BRNG_SFMT19937,RNG%seed)
        End If
        If (Not(rng_stat.EQ.VSL_ERROR_OK .OR. rng_stat.EQ.VSL_STATUS_OK)) Call Output_Message('ERROR:  Random_Numbers: Initialize_RNG:  MKL RNG stream creation failed, STAT = ',rng_stat,kill=.TRUE.)
        rng_stat = vdrnguniform(VSL_RNG_METHOD_UNIFORM_STD,RNG%stream,RNG%q_size,RNG%q,0._dp,1._dp)
        If (Not(rng_stat.EQ.VSL_ERROR_OK .OR. rng_stat.EQ.VSL_STATUS_OK)) Call Output_Message('ERROR:  Random_Numbers: Initialize_RNG:  MKL RNG stream initial fill q failed, STAT = ',rng_stat,kill=.TRUE.)
#   else
        If (Present(thread)) Then  !Parallel execution
            Call Output_Message('ERROR:  Random_Numbers: Initialize_RNG:  Local MT19937 PRNG not configured for parallel execution.',kill=.TRUE.)
            !HACK Parallel implementation with single local MT19937 run by worker #1
            If (thread .EQ. 0) Call RNG%stream%seed(RNG%seed)
            Call Do_RNG_Stream_Files(RNG) !<--This routine contains a SYNC ALL barrier
            RNG%RNG_by_Stream_Files = .TRUE.
        Else  !serial execution
            Call RNG%stream%seed(RNG%seed)
            Do i = 1,RNG%q_size
                RNG%q(i) = RNG%stream%r()
            End Do
            RNG%RNG_by_Stream_Files = .FALSE.
        End If
#   endif
    RNG%q_index = 1
    RNG%q_refreshed = 1
End Subroutine Initialize_RNG

Subroutine Do_RNG_Stream_Files(RNG)
    Use Kinds, Only: dp
    Use FileIO_Utilities, Only: max_path_len
    Use FileIO_Utilities, Only: slash
    Use FileIO_Utilities, Only: Var_to_file
    Use FileIO_Utilities, Only: Var_from_file
    Use FileIO_Utilities, Only: n_Workers
    Use FileIO_Utilities, Only: Worker_Index
    Use FileIO_Utilities, Only: Working_Directory
    Use FileIO_Utilities, Only: Check_Directory
    Use FileIO_Utilities, Only: Create_Directory
    Implicit None
    Type(RNG_Type), Intent(InOut) :: RNG
    Character(max_path_len) :: dir
    Character(:), Allocatable :: file_dir
    Character(:), Allocatable :: fname
    Integer :: i,j
    Character(4) :: ichar

    Call Working_Directory(GETdir=dir,s=slash)
    Allocate(Character(max_path_len) :: file_dir)
    file_dir = Trim(dir)//'temp'//slash
    Allocate(Character(max_path_len) :: fname)
    If (Worker_Index() .EQ. 1) Then !worker #1 runs the RNG, all others wait at the following SYNC statement
        !Create a stream file for each worker
        !Check if temp results directory exists
        If (.NOT. Check_Directory(file_dir)) Call Create_Directory(file_dir)
        Do j = 1,n_Workers()
            Do i = 1,RNG%q_size
                RNG%q(i) = RNG%stream%r()
            End Do
            Write(ichar,'(I4.4)') j
            fname = file_dir//'stream'//ichar//'.rng'
            Call Var_to_file( RNG%q, fname )
        End Do
    End If
#   if CAF
        SYNC ALL
#   endif
    !Each worker may now retrieve the array of random numbers from its own stream file
    Write(ichar,'(I4.4)') Worker_Index()
    fname = file_dir//'stream'//ichar//'.rng'
    Call Var_from_file( RNG%q, fname, delete_file=.TRUE. ) !DELETE the file so that future access will fail if attempted before a new stream file is generated
End Subroutine Do_RNG_Stream_Files

Function Get_1_Random(RNG) Result(r)
    Use Kinds, Only: dp
    Implicit None
    Real(dp) :: r
    Class(RNG_Type), Intent(InOut) :: RNG  !RNG stream state variable from which to get r
    
    r = RNG%q(RNG%q_index)  !get random number from the array
    If (RNG%q_index .EQ. RNG%q_size) Then !random array exhaused, need to refresh q
        Call Refresh_Random_Array(RNG)
    Else  !increment index
        RNG%q_index = RNG%q_index + 1
    End If
End Function Get_1_Random

Function Get_n_Randoms(RNG,n) Result(r)
    Use Kinds, Only: dp
    Implicit None
    Class(RNG_Type), Intent(InOut) :: RNG
    Integer,Intent(In) :: n  !number of elements in r
    Real(dp) :: r(n)
    Integer :: m
    
    m = RNG%q_index + n - 1  !index of the final q needed to fill r
    If (m .LE. RNG%q_size) Then  !There are enough numbers left in th array for the request
        r = RNG%q(RNG%q_index:m)
        RNG%q_index = RNG%q_index + n
    Else  !There are not enough numbers in the array for the request
        m = RNG%q_size - RNG%q_index + 1  !q remaining in random array
        r(1:m) = RNG%q(RNG%q_index:RNG%q_size)  !exhaust the random array into the first m entries of r
        Call Refresh_Random_Array(RNG)  !Refresh the random array
        r(m+1:n) = RNG%q(1:n-m)  !fill the remaining n-m entries of r
        RNG%q_index = n - m + 1
    End If
    If (RNG%q_index .GE. RNG%q_size) Then !random array exhaused, need to refresh q
        Call Refresh_Random_Array(RNG)
    End If
End Function Get_n_Randoms

Subroutine Refresh_Random_Array(RNG)
#   if IMKL
        Use MKL_VSL, Only: VSL_ERROR_OK,VSL_STATUS_OK
        Use MKL_VSL, Only: vdrnguniform,VSL_RNG_METHOD_UNIFORM_STD
#   endif
    Use Kinds, Only: dp
    Use FileIO_Utilities, Only: Output_Message
    Implicit None
    Type(RNG_Type), Intent(InOut) :: RNG
#   if IMKL
        Integer :: rng_stat  !status returns from MKL RNG operations
#   else
        Integer :: i
#   endif
    
#   if IMKL
        rng_stat = vdrnguniform(VSL_RNG_METHOD_UNIFORM_STD,RNG%stream,RNG%q_size,RNG%q,0._dp,1._dp)
        If (Not(rng_stat.EQ.VSL_ERROR_OK .OR. rng_stat.EQ.VSL_STATUS_OK)) Call Output_Message('ERROR:  Random_Numbers: Refresh_Random_Array:  MKL RNG q_fill failed, STAT = ',rng_stat,kill=.TRUE.)
#   else
        If (RNG%RNG_by_Stream_Files) Then
            Call Do_RNG_Stream_Files(RNG) !<--This routine contains a SYNC ALL barrier
        Else
            Do i = 1,RNG%q_size
                RNG%q(i) = RNG%stream%r()
            End Do
        End If
#   endif
    RNG%q_index = 1
    RNG%q_refreshed = RNG%q_refreshed + 1
End Subroutine Refresh_Random_Array

!HACK This routine is commented out because it may no longer be required in the scope of the project...
! Subroutine Restart_RNG(RNG)
!     Use OMP_LIB, Only: OMP_GET_NUM_THREADS,OMP_GET_THREAD_NUM
!     Use MKL_VSL, Only: vsldeletestream,vslnewstream
!     Use MKL_VSL, Only: VSL_BRNG_MT2203,VSL_BRNG_SFMT19937
!     Use MKL_VSL, Only: VSL_ERROR_OK,VSL_STATUS_OK
!     Use MKL_VSL, Only: vdrnguniform,VSL_RNG_METHOD_UNIFORM_STD
!     Implicit None
!     Class(RNG_Type), Intent(InOut) :: RNG
!     Integer :: rng_stat  !status returns from MKL RNG operations
!     Integer :: thread
    
!     rng_stat = vsldeletestream(RNG%stream)
!     If (OMP_GET_NUM_THREADS().GT.1 .OR. num_images().GT.1) Then !setup is being called from inside a parallel region
!         If (OMP_GET_NUM_THREADS() .GT. 1) Then  !use the OpenMP thread number to choose the RNG stream
!             thread = OMP_GET_THREAD_NUM()  !OpenMP threads are numbered starting at zero
!         Else If (num_images() .GT. 1) Then  !use the coarray image number to choose the RNG stream
!             thread = this_image() - 1  !coarray images are numbered starting at 1
!         Else
!             Print *,'ERROR:  Random_Numbers: Restart_RNG:  Unable to resolve thread or image number.'
!             ERROR STOP
!         End If
!         rng_stat = vslnewstream(RNG%stream,VSL_BRNG_MT2203+thread,RNG%seed)
!     Else  !initialize for serial execution
!         rng_stat = vslnewstream(RNG%stream,VSL_BRNG_SFMT19937,RNG%seed)
!     End If
!     If (Not(rng_stat.EQ.VSL_ERROR_OK .OR. rng_stat.EQ.VSL_STATUS_OK)) Then
!         Print *,'ERROR:  Random_Numbers: Restart_RNG:  MKL RNG stream creation failed, STAT = ',rng_stat
!         ERROR STOP
!     End If
!     rng_stat = vdrnguniform(VSL_RNG_METHOD_UNIFORM_STD,RNG%stream,RNG%q_size,RNG%q,0._dp,1._dp)
!     If (Not(rng_stat.EQ.VSL_ERROR_OK .OR. rng_stat.EQ.VSL_STATUS_OK)) Then
!         Print *,'ERROR:  Random_Numbers: Restart_RNG:  MKL RNG stream initial fill q failed, STAT = ',rng_stat
!         ERROR STOP
!     End If
!     RNG%q_index = 1
! End Subroutine Restart_RNG

Subroutine Cleanup_RNG(RNG)
#   if IMKL
        Use MKL_VSL, Only: vsldeletestream
#   endif
    Implicit None
    Class(RNG_Type), Intent(InOut) :: RNG
#   if IMKL
        Integer :: rng_stat  !status returns from MKL RNG operations
#   endif
    
#   if IMKL
        rng_stat = vsldeletestream(RNG%stream)
#   else
        RNG%stream%mt = 0
        RNG%stream%mti = HUGE(RNG%stream%mti)
        RNG%stream%seeded = .FALSE.
#   endif
    Deallocate(RNG%q)
    RNG%q_size = 0
    RNG%q_index = 0
    RNG%seed = 0
    RNG%q_refreshed = 0
End Subroutine Cleanup_RNG

Subroutine Save_RNG(RNG,dir)
#   if IMKL
        Use MKL_VSL, Only: vslsavestreamF
#   endif
    Use FileIO_Utilities, Only: Worker_Index
    Use FileIO_Utilities, Only: max_path_len
    Use FileIO_Utilities, Only: Var_to_file
#   if IMKL
        Use FileIO_Utilities, Only: Output_Message
#   endif
    Implicit None
    Class(RNG_Type), Intent(In) :: RNG
    Character(*), Intent(In) :: dir
    Character(4) :: i_char
    Character(:), Allocatable :: fname
#   if IMKL
        Integer :: stat
#   endif
    
    Write(i_char,'(I4.4)') Worker_Index()
    Allocate(Character(max_path_len) :: fname)
    fname = dir//'RNGstate'//i_char//'.bin'
#   if IMKL
        stat = vslsavestreamF( RNG%stream, fname )
        If (stat .NE. 0) Call Output_Message('ERROR:  Random_Numbers: Save_RNG:  File open error, '//fname//', IOSTAT=',stat,kill=.TRUE.)
#   else
        Call RNG%stream%save(fname)
#   endif
    fname = dir//'RNGs'//i_char//'.bin'
    Call Var_to_file( RNG%seed , fname )
    fname = dir//'RNGqs'//i_char//'.bin'
    Call Var_to_file( RNG%q_size , fname )
    fname = dir//'RNGqi'//i_char//'.bin'
    Call Var_to_file( RNG%q_index, fname )
    fname = dir//'RNGq'//i_char//'.bin'
    Call Var_to_file( RNG%q, fname )
    fname = dir//'RNGqr'//i_char//'.bin'
    Call Var_to_file( RNG%q_refreshed, fname )
End Subroutine Save_RNG

Subroutine Load_RNG(RNG,dir)
#   if IMKL
        Use MKL_VSL, Only: vslloadstreamF
        Use FileIO_Utilities, Only: Output_Message
#   endif
    Use FileIO_Utilities, Only: Worker_Index
    Use FileIO_Utilities, Only: max_path_len
    Use FileIO_Utilities, Only: Var_from_file
    Implicit None
    Class(RNG_Type), Intent(Out) :: RNG
    Character(*), Intent(In) :: dir
    Character(4) :: i_char
    Character(:), Allocatable :: fname
#   if IMKL
        Integer :: stat
#   endif
    
    Write(i_char,'(I4.4)') Worker_Index()
    Allocate(Character(max_path_len) :: fname)
    fname = dir//'RNGstate'//i_char//'.bin'
#   if IMKL
        stat = vslloadstreamF( RNG%stream, fname )
        If (stat .NE. 0) Call Output_Message('ERROR:  Random_Numbers: Load_RNG:  File open error, '//fname//', IOSTAT=',stat,kill=.TRUE.)
#   else
        Call RNG%stream%load(fname)
#   endif
    fname = dir//'RNGs'//i_char//'.bin'
    Call Var_from_file( RNG%seed , fname )
    fname = dir//'RNGqs'//i_char//'.bin'
    Call Var_from_file( RNG%q_size , fname )
    fname = dir//'RNGqi'//i_char//'.bin'
    Call Var_from_file( RNG%q_index, fname )
    Allocate(RNG%q(1:RNG%q_size))
    fname = dir//'RNGq'//i_char//'.bin'
    Call Var_from_file( RNG%q, fname )
    fname = dir//'RNGqr'//i_char//'.bin'
    Call Var_from_file( RNG%q_refreshed, fname )
End Subroutine Load_RNG

!TODO The following functions are beginnings of routines for inverting generalized CDFs for sampling
! Function Invert_CDF_O1(xi,x1,x2) Result(x)
!     !Inverts the CDF from a general uniform probability distribution (PDF order zero, CDF order 1)
!     Use Kinds, Only: dp
!     Implicit None
!     Real(dp) :: x
!     Real(dp), Intent(In) :: xi  !sampled cumulative probability [0,1)
!     Real(dp), Intent(In) :: x1,x2  !range of x
    
!     x = x1 + xi * (x2 - x1)
! End Function Invert_CDF_O0

! Function Invert_CDF_O2(xi,x1,dx,y1,m) Result(x)
!     !Inverts the CDF from a general linear probability distribution (PDF order 1, CDF order 2)
!     Use Kinds, Only: dp
!     Use Utilities, Only: Larger_Quadratic_root
!     Implicit None
!     Real(dp) :: x
!     Real(dp), Intent(In) :: xi  !sampled cumulative probability [0,1)
!     Real(dp), Intent(In) :: x1,dx  !starting value and range of x
!     Real(dp), Intent(In) :: y1  !pdf vaues at x1
!     Real(dp), Intent(In) :: m  !pdf slope
!     Real(dp) :: b,c
    
!     b = y1/m - x1
!     c = (x1*(2._dp*y1 - m*x1) + dx*xi*(dx*m + 2._dp*y1)) / m
!     x = Larger_Quadratic_root(b,c)
!     !The larger quadratic root is computed first for precision, but only one of the roots lies between x1 and x2
!     !If the larger root is not on (x1,x2), then the smaller root is:
!     If (x.GT.x2 .OR. x.LT.x1) x = -c / x
! End Function Invert_CDF_O2

! Function Invert_CDF_O2(xi,x1,dx,y1,y2) Result(x)
!     !Inverts the CDF from a general quadratic probability distribution (PDF order 2, CDF order 3)
!     Use Kinds, Only: dp
!     Implicit None
!     Real(dp) :: x
!     Real(dp), Intent(In) :: xi  !sampled cumulative probability [0,1)
!     Real(dp), Intent(In) :: x1,dx  !!starting value and range of x
!     Real(dp), Intent(In) :: y1,y2  !pdf vaues at x1 and x2
!     Real(dp) :: b,c
    
! End Function Invert_CDF_O2

End Module Random_Numbers
