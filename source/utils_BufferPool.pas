(*
 * 内存池单元
 *   内存块通过引用计数，归还到池
 *
*)

unit utils_BufferPool;

interface

{$DEFINE USE_SPINLOCK}

/// 如果不进行sleep会跑满cpu。
/// spinlock 交换失败时会执行sleep
{$DEFINE SPINLOCK_SLEEP}

uses
  SyncObjs, SysUtils
  {$IFDEF MSWINDOWS}
  , Windows
  {$ELSE}

  {$ENDIF};

{$IF defined(FPC) or (RTLVersion>=18))}
  {$DEFINE HAVE_INLINE}
{$IFEND HAVE_INLINE}

const
  block_flag :Word = $1DFB;

{$IFDEF DEBUG}
  protect_size = 8;
{$ELSE}
  protect_size = 2;
{$ENDIF}

type
 
  PBufferPool = ^ TBufferPool;
  PBufferBlock = ^TBufferBlock;
  
  TBufferPool = record
    FBlockSize: Integer;
    FHead:PBufferBlock;
    FGet:Integer;
    FPut:Integer;
    FSize:Integer;
    FAddRef:Integer;
    FReleaseRef:Integer;

    {$IFDEF USE_SPINLOCK}
    FSpinLock:Integer;
    FLockWaitCounter: Integer;
    {$ELSE}
    FLocker:TCriticalSection;
    {$ENDIF}

    FName:String;

  end;



  TBufferBlock = record
    flag: Word;
    refcounter :Integer;
    next: PBufferBlock;
    owner: PBufferPool;
    data: Pointer;
    data_free_type:Byte; // 0,
  end;

  TBufferNotifyEvent = procedure(pvSender: TObject; pvBuffer: Pointer; pvLength:
      Integer) of object;
  TBlockBuffer = class(TObject)
  private
    FBlockSize: Integer;
    FSize:Integer;
    FPosition:Integer;
    FBuffer: Pointer;
    FBufferPtr:PByte;
    FBufferPool: PBufferPool;
    FOnBufferWrite: TBufferNotifyEvent;
    procedure CheckBlockBuffer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
  public
    constructor Create(ABufferPool: PBufferPool);
    procedure SetBufferPool(ABufferPool: PBufferPool);
    procedure Append(pvBuffer:Pointer; pvLength:Integer);{$IFDEF HAVE_INLINE} inline;{$ENDIF}
    destructor Destroy; override;
    procedure FlushBuffer();
    procedure ClearBuffer();
    property OnBufferWrite: TBufferNotifyEvent read FOnBufferWrite write FOnBufferWrite;
  end;

const
  BLOCK_SIZE = SizeOf(TBufferBlock);

  FREE_TYPE_NONE = 0;
  FREE_TYPE_FREEMEM = 1;
  FREE_TYPE_DISPOSE = 2;
  FREE_TYPE_OBJECTFREE = 3;
  FREE_TYPE_OBJECTNONE = 4;


function NewBufferPool(pvBlockSize: Integer = 1024): PBufferPool;
procedure FreeBufferPool(buffPool:PBufferPool);

function GetBuffer(ABuffPool:PBufferPool): PByte;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
procedure FreeBuffer(pvBuffer:PByte; pvReleaseAttachDataAtEnd:Boolean=True);{$IFDEF HAVE_INLINE} inline;{$ENDIF}

function AddRef(pvBuffer:PByte): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}

/// <summary>
///   减少对内存块的引用
///   为0时，释放data数据
/// </summary>
function ReleaseRef(pvBuffer:PByte): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF} overload;
function ReleaseRef(pvBuffer:Pointer; pvReleaseAttachDataAtEnd:Boolean):
    Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF} overload;


/// <summary>
///   附加一个数据
/// </summary>
procedure AttachData(pvBuffer, pvData: Pointer; pvFreeType: Byte);

/// <summary>
///   获取附加的数据
///   0:成功
///   1:没有
/// </summary>
function GetAttachData(pvBuffer: Pointer; var X: Pointer): Integer;


function GetAttachDataAsObject(pvBuffer:Pointer): TObject;

/// <summary>
///  检测池中内存块越界情况
/// </summary>
function CheckBufferBounds(ABuffPool:PBufferPool): Integer;

{$IF RTLVersion<24}
function AtomicCmpExchange(var Target: Integer; Value: Integer;
  Comparand: Integer): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF}
function AtomicIncrement(var Target: Integer): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
function AtomicDecrement(var Target: Integer): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
{$IFEND <XE5}

procedure SpinLock(var Target:Integer; var WaitCounter:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF} overload;
procedure SpinLock(var Target:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF} overload;
procedure SpinUnLock(var Target:Integer); {$IFDEF HAVE_INLINE} inline;{$ENDIF}overload;




{$if CompilerVersion < 18} //before delphi 2007
function InterlockedCompareExchange(var Destination: Longint; Exchange: Longint; Comperand: Longint): Longint stdcall; external kernel32 name 'InterlockedCompareExchange';
{$EXTERNALSYM InterlockedCompareExchange}
{$ifend}

procedure FreeObject(AObject: TObject); {$IFDEF HAVE_INLINE} inline;{$ENDIF}

implementation

procedure FreeObject(AObject: TObject);
begin
{$IFDEF AUTOREFCOUNT}
  AObject.DisposeOf;
{$ELSE}
  AObject.Free;
{$ENDIF}
end;

procedure ReleaseAttachData(pvBlock:PBufferBlock); {$IFDEF HAVE_INLINE} inline;{$ENDIF} 
begin
  if pvBlock.data <> nil then
  begin
    case pvBlock.data_free_type of
      0: ;
      1: FreeMem(pvBlock.data);
      2: Dispose(pvBlock.data);
      3: FreeObject(pvBlock.data);
{$IFDEF AUTOREFCOUNT}
      FREE_TYPE_OBJECTNONE: TObject(pvBlock.data).__ObjRelease;
{$ENDIF}

    else
      Assert(False, Format('BufferBlock[%s] unkown data free type:%d', [pvBlock.owner.FName, pvBlock.data_free_type]));
    end;
    pvBlock.data := nil;
  end;   
end;

procedure SpinLock(var Target:Integer; var WaitCounter:Integer);
begin
  while AtomicCmpExchange(Target, 1, 0) <> 0 do
  begin
    AtomicIncrement(WaitCounter);
//    {$IFDEF MSWINDOWS}
//      SwitchToThread;
//    {$ELSE}
//      TThread.Yield;
//    {$ENDIF}
    {$IFDEF SPINLOCK_SLEEP}
    Sleep(1);    // 1 对比0 (线程越多，速度越平均)
    {$ENDIF}
  end;
end;

procedure SpinLock(var Target:Integer);
begin
  while AtomicCmpExchange(Target, 1, 0) <> 0 do
  begin
    {$IFDEF SPINLOCK_SLEEP}
    Sleep(1);    // 1 对比0 (线程越多，速度越平均)
    {$ENDIF}
  end;
end;


procedure SpinUnLock(var Target:Integer);
begin
  if AtomicCmpExchange(Target, 0, 1) <> 1 then
  begin
    Assert(False, 'SpinUnLock::AtomicCmpExchange(Target, 0, 1) <> 1');
  end;
end;



{$IF RTLVersion<24}
function AtomicCmpExchange(var Target: Integer; Value: Integer;
  Comparand: Integer): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := InterlockedCompareExchange(Target, Value, Comparand);
{$ELSE}
  Result := TInterlocked.CompareExchange(Target, Value, Comparand);
{$ENDIF}
end;

function AtomicIncrement(var Target: Integer): Integer;{$IFDEF HAVE_INLINE} inline;{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := InterlockedIncrement(Target);
{$ELSE}
  Result := TInterlocked.Increment(Target);
{$ENDIF}
end;

function AtomicDecrement(var Target: Integer): Integer; {$IFDEF HAVE_INLINE} inline;{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := InterlockedDecrement(Target);
{$ELSE}
  Result := TInterlocked.Decrement(Target);
{$ENDIF}
end;

{$IFEND <XE5}

/// <summary>
///   检测一块内存是否有越界情况
///   false 有越界清空
/// </summary>
function CheckBufferBlockBounds(ABlock: PBufferBlock): Boolean;
var
  lvBuffer:PByte;
  i:Integer;
begin
  Result := True;
  lvBuffer:= PByte(ABlock);
  Inc(lvBuffer, BLOCK_SIZE + ABlock.owner.FBlockSize);

  for I := 0 to protect_size - 1 do
  begin
    if lvBuffer^ <> 0 then
    begin
      Result := False;
      Break;
    end;
    Inc(lvBuffer);
  end;

end;

function GetBuffer(ABuffPool:PBufferPool): PByte;
var
  lvBuffer:PBufferBlock;
begin
  {$IFDEF USE_SPINLOCK}
  SpinLock(ABuffPool.FSpinLock, ABuffPool.FLockWaitCounter);
  {$ELSE}
  ABuffPool.FLocker.Enter;
  {$ENDIF}
  // 获取一个节点
  lvBuffer := PBufferBlock(ABuffPool.FHead);
  if lvBuffer <> nil then ABuffPool.FHead := lvBuffer.next;
  {$IFDEF USE_SPINLOCK}
  SpinUnLock(ABuffPool.FSpinLock);
  {$ELSE}
  ABuffPool.FLocker.Leave;
  {$ENDIF}


  if lvBuffer = nil then
  begin
    // + 2保护边界(可以检测内存越界写入)
    GetMem(Result, BLOCK_SIZE + ABuffPool.FBlockSize + protect_size);
    {$IFDEF DEBUG}
    FillChar(Result^, BLOCK_SIZE + ABuffPool.FBlockSize + protect_size, 0);
    {$ELSE}
    FillChar(Result^, BLOCK_SIZE, 0);
    {$ENDIF}
    lvBuffer := PBufferBlock(Result);
    lvBuffer.owner := ABuffPool;
    lvBuffer.flag := block_flag;


    AtomicIncrement(ABuffPool.FSize);
  end else
  begin
    Result := PByte(lvBuffer);
  end;     

  Inc(Result, BLOCK_SIZE);
  AtomicIncrement(ABuffPool.FGet);
end;

/// <summary>
///  释放内存块到Owner的列表中
/// </summary>
procedure InnerFreeBuffer(pvBufBlock:PBufferBlock);{$IFDEF HAVE_INLINE} inline;{$ENDIF}
var
  lvBuffer:PBufferBlock;
  lvOwner:PBufferPool;
begin
  lvOwner := pvBufBlock.owner;
  {$IFDEF USE_SPINLOCK}
  SpinLock(lvOwner.FSpinLock, lvOwner.FLockWaitCounter);
  {$ELSE}
  lvOwner.FLocker.Enter;
  {$ENDIF}
  lvBuffer := lvOwner.FHead;
  pvBufBlock.next := lvBuffer;
  lvOwner.FHead := pvBufBlock;
  {$IFDEF USE_SPINLOCK}
  SpinUnLock(lvOwner.FSpinLock);
  {$ELSE}
  lvOwner.FLocker.Leave;
  {$ENDIF}
  AtomicIncrement(lvOwner.FPut);
end;



function AddRef(pvBuffer:PByte): Integer;
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock;
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');
  Result := AtomicIncrement(lvBlock.refcounter);
  AtomicIncrement(lvBlock.owner.FAddRef);
end;

function ReleaseRef(pvBuffer:PByte): Integer;
begin
  Result := ReleaseRef(pvBuffer, True);
end;

function NewBufferPool(pvBlockSize: Integer = 1024): PBufferPool;
begin
  New(Result);
  Result.FBlockSize := pvBlockSize;
  Result.FHead := nil;
  {$IFDEF USE_SPINLOCK}
  Result.FSpinLock := 0;
  Result.FLockWaitCounter := 0;
  {$ELSE}
  Result.FLocker := TCriticalSection.Create;
  {$ENDIF}

  Result.FGet := 0;
  Result.FSize := 0;
  Result.FPut := 0;
  Result.FAddRef := 0;
  Result.FReleaseRef :=0;
  
end;

procedure FreeBufferPool(buffPool:PBufferPool);
var
  lvBlock, lvNext:PBufferBlock;
begin
  Assert(buffPool.FGet = buffPool.FPut,
    Format('DBuffer-%s Leak, get:%d, put:%d', [buffPool.FName, buffPool.FGet, buffPool.FPut]));

  lvBlock := buffPool.FHead;
  while lvBlock <> nil do
  begin
    lvNext := lvBlock.next;
    ReleaseAttachData(lvBlock);
    FreeMem(lvBlock);
    lvBlock := lvNext;
  end;
  {$IFDEF USE_SPINLOCK}
  ;
  {$ELSE}
  buffPool.FLocker.Free;
  {$ENDIF}

  Dispose(buffPool);
end;

function CheckBufferBounds(ABuffPool:PBufferPool): Integer;
var
  lvBlock:PBufferBlock;  
begin
  if protect_size = 0 then
  begin   // 没有保护边界的大小
    Result := -1;
    Exit;
  end;
  Result := 0;
  {$IFDEF USE_SPINLOCK}
  SpinLock(ABuffPool.FSpinLock, ABuffPool.FLockWaitCounter);
  {$ELSE}
  ABuffPool.FLocker.Enter;
  {$ENDIF}
  lvBlock := ABuffPool.FHead;
  while lvBlock <> nil do
  begin
    if not CheckBufferBlockBounds(lvBlock) then Inc(Result);

    lvBlock := lvBlock.next;
  end;
  {$IFDEF USE_SPINLOCK}
  SpinUnLock(ABuffPool.FSpinLock);
  {$ELSE}
  ABuffPool.FLocker.Leave;
  {$ENDIF}
end;

procedure AttachData(pvBuffer, pvData: Pointer; pvFreeType: Byte);
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock;
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');

  ReleaseAttachData(lvBlock);

  lvBlock.data := pvData;
  lvBlock.data_free_type := pvFreeType;

{$IFDEF AUTOREFCOUNT}
  if pvFreeType in [FREE_TYPE_OBJECTFREE, FREE_TYPE_OBJECTNONE] then
    TObject(pvData).__ObjAddRef();
{$ENDIF}
end;

function GetAttachData(pvBuffer: Pointer; var X: Pointer): Integer;
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock;
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');

  if lvBlock.data <> nil then
  begin
    X := lvBlock.data;
    Result := 0;
  end else
  begin
    Result := -1;
  end;
end;

function GetAttachDataAsObject(pvBuffer:Pointer): TObject;
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock;
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');

  if lvBlock.data <> nil then
  begin
    Result :=TObject(lvBlock.data);
  end else
  begin
    Result := nil;
  end;
end;

function ReleaseRef(pvBuffer:Pointer; pvReleaseAttachDataAtEnd:Boolean):
    Integer; overload;
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock;
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');
  Result := AtomicDecrement(lvBlock.refcounter);
  AtomicIncrement(lvBlock.owner.FReleaseRef);
  if Result = 0 then
  begin
    if pvReleaseAttachDataAtEnd then
      ReleaseAttachData(lvBlock);
    InnerFreeBuffer(lvBlock);
  end else
  begin
    Assert(Result > 0, 'DBuffer error release');
  end;
end;

procedure FreeBuffer(pvBuffer:PByte; pvReleaseAttachDataAtEnd:Boolean);
var
  lvBuffer:PByte;
  lvBlock:PBufferBlock;
begin
  lvBuffer := pvBuffer;
  Dec(lvBuffer, BLOCK_SIZE);
  lvBlock := PBufferBlock(lvBuffer);
  Assert(lvBlock.flag = block_flag, 'invalid DBufferBlock');
  {$IFDEF DEBUG}
  Assert(lvBlock.refcounter = 0, Format('DBufferBlock:: buffer is in use, refcount:%d', [lvBlock.refcounter]));
  {$ENDIF}
  if pvReleaseAttachDataAtEnd then
    ReleaseAttachData(lvBlock);
  InnerFreeBuffer(lvBlock);
end;

procedure TBlockBuffer.Append(pvBuffer: Pointer; pvLength: Integer);
var
  r, l, s:Integer;
  lvBuff:PByte;
begin  
  lvBuff := PByte(pvBuffer);
  r := pvLength;
  while r > 0 do
  begin
    CheckBlockBuffer;
    if FPosition + r > FBlockSize then l := FBlockSize - FPosition else l := r;

    Move(lvBuff^, FBufferPtr^, l);
    Dec(r, l);
    Inc(lvBuff, l);
    Inc(FBufferPtr, l);
    Inc(FPosition, l);
    Inc(FSize, l);
    if FPosition = FBlockSize then
    begin
      FlushBuffer;
    end;     
  end;
end;

constructor TBlockBuffer.Create(ABufferPool: PBufferPool);
begin
  inherited Create;
  SetBufferPool(ABufferPool);
end;

destructor TBlockBuffer.Destroy;
begin
  FlushBuffer;
  inherited Destroy;
end;

procedure TBlockBuffer.FlushBuffer;
begin
  if FBuffer = nil then Exit;
  try                        
    if (Assigned(FOnBufferWrite) and (FSize > 0)) then
    begin
      AddRef(FBuffer);
      try
        FOnBufferWrite(self, FBuffer, FSize);
      finally
        ReleaseRef(FBuffer);
      end;
    end else
    begin
      if FBuffer <> nil then FreeBuffer(FBuffer);
    end;
  finally
    FBuffer := nil;
  end;
end;

procedure TBlockBuffer.SetBufferPool(ABufferPool: PBufferPool);
begin
  FBufferPool := ABufferPool;
  if FBufferPool <> nil then
  begin
    FBlockSize := FBufferPool.FBlockSize;
  end else
  begin
    FBlockSize := 0;
  end;
  FBuffer := nil;
end;

procedure TBlockBuffer.CheckBlockBuffer;
begin
  if FBuffer = nil then
  begin
    FBuffer := GetBuffer(FBufferPool);
    FBufferPtr := PByte(FBuffer);
    FPosition := 0;
    FSize := 0;
  end;
  
end;






procedure TBlockBuffer.ClearBuffer;
begin
  if FBuffer = nil then Exit;
  try                        
    if FBuffer <> nil then FreeBuffer(FBuffer);
  finally
    FBuffer := nil;
  end;  
end;

end.
