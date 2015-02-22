(*
 *	 Unit owner: D10.Mofen
 *	       blog: http://www.cnblogs.com/dksoft
 *
 *	 v3.0.1(2014-7-16 21:36:30)
 *     + first release
 *
 *   2014-08-12 21:47:34
 *     + add Enable property
 *
 *   2014-10-12 00:50:06
 *     + add signal task
 *)
unit diocp.task;

interface

uses
  diocp.core.engine, SysUtils, utils.queues, Messages, Windows, Classes,
  SyncObjs, utils.hashs, utils.locker;

const
  WM_REQUEST_TASK = WM_USER + 1;

type
  TIocpTaskRequest = class;
  TIocpTaskMananger = class;

  TOnTaskWorkStrData = procedure(strData: String) of object;
  TOnTaskWorkNoneData = procedure() of object;
  
  TOnTaskWork = procedure(pvTaskRequest: TIocpTaskRequest) of object;
  TOnTaskWorkProc = procedure(pvTaskRequest: TIocpTaskRequest);

  /// rtPostMessage: use in dll project
  TRunInMainThreadType = (rtSync, rtPostMessage);

  TDataFreeType = (ftNone, ftFreeAsObject, ftUseDispose);

  TSignalTaskData = class(TObject)
  private
    FSignalID: Integer;
    FOnTaskWork: TOnTaskWork;
  end;

  TSimpleDataObject = class(TObject)
  private
    FData: Pointer;
    FDataString1: String;
    FDataString2: string;
    FIntValue1: Integer;
    FIntValue2: Integer;
  public
    constructor Create(const ADataString1: String; const ADataString2: String = '';
        AIntValue1: Integer = 0; AIntValue2: Integer = 0);
    property Data: Pointer read FData write FData;
    property DataString1: String read FDataString1 write FDataString1;
    property DataString2: string read FDataString2 write FDataString2;
    property IntValue1: Integer read FIntValue1 write FIntValue1;
    property IntValue2: Integer read FIntValue2 write FIntValue2;
  end;

  TIocpTaskRequest = class(TIocpRequest)
  private
    FFreeType: TDataFreeType;
    FStartTime: Cardinal;
    FEndTime: Cardinal;
    FOwner:TIocpTaskMananger;
    FMessageEvent: TEvent;
    FStrData:String;
    FOnTaskWork: TOnTaskWork;
    FOnTaskWorkProc :TOnTaskWorkProc;
    FOnTaskWorkStrData :TOnTaskWorkStrData;
    FOnTaskWorkNoneData :TOnTaskWorkNoneData;

    FRunInMainThread: Boolean;
    FRunInMainThreadType: TRunInMainThreadType;
    FTaskData:Pointer;
    procedure DoCleanUp;
    procedure InnerDoTask;
  protected
    procedure HandleResponse; override;
    function GetStateINfo: String; override;
  public
    constructor Create;
    destructor Destroy; override;
    property TaskData: Pointer read FTaskData;
  end;

  TIocpTaskMananger = class(TObject)
  private
    FLocker:TIocpLocker;

    FActive: Boolean;
    FEnable: Boolean;
    FIocpEngine: TIocpEngine;

    FPostCounter: Integer;
    FErrorCounter: Integer;
    FFireTempWorker: Boolean;
    FResponseCounter: Integer;

    FSignalTasks: TDHashTable;

    procedure OnSignalTaskDelete(PHashData: Pointer);

    procedure SetActive(const Value: Boolean);

    procedure incResponseCounter();
    procedure incErrorCounter();

    procedure InnerPostTask(pvRequest: TIocpTaskRequest);

  protected
    FMessageHandle: HWND;
    procedure DoMainThreadWork(var AMsg: TMessage);
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    ///   task current info
    /// </summary>
    function getStateINfo: String;

    /// <summary>
    ///   will stop diocp.core.engine and lose jobs
    /// </summary>
    procedure setWorkerCount(pvCounter:Integer);

    procedure PostATask(pvTaskWork:TOnTaskWorkNoneData; pvRunInMainThread:Boolean =
        False; pvRunType:TRunInMainThreadType = rtSync); overload;

    procedure PostATask(pvTaskWork:TOnTaskWorkStrData; pvStrData:string;
        pvRunInMainThread:Boolean = False; pvRunType:TRunInMainThreadType =
        rtSync); overload;

    procedure PostATask(pvTaskWork:TOnTaskWork; pvStrData:string;
        pvRunInMainThread:Boolean = False; pvRunType:TRunInMainThreadType =
        rtSync); overload;

    procedure PostATask(pvTaskWork:TOnTaskWork;
       pvTaskData:Pointer = nil;
       pvRunInMainThread:Boolean = False;
       pvRunType:TRunInMainThreadType = rtSync);overload;

    procedure PostATask(pvTaskWorkProc: TOnTaskWorkProc; pvTaskData: Pointer = nil;
        pvRunInMainThread: Boolean = False; pvRunType: TRunInMainThreadType =
        rtSync); overload;


    /// <summary>
    ///   regsiter a signal, binding callback procedure to a signal
    /// </summary>
    procedure registerSignal(pvSignalID: Integer; pvTaskWork: TOnTaskWork);

    /// <summary>
    ///   regsiter a signal, binding callback procedure to a signal
    /// </summary>
    function UnregisterSignal(pvSignalID:Integer): Boolean;

    /// <summary>
    ///   post a signal task
    /// </summary>
    procedure SignalATask(pvSignalID: Integer; pvTaskData: Pointer = nil;
        pvDataFreeType: TDataFreeType = ftNone; pvRunInMainThread: Boolean = False;
        pvRunType: TRunInMainThreadType = rtSync); overload;


    property Active: Boolean read FActive write SetActive;

    property Enable: Boolean read FEnable write FEnable;

    property FireTempWorker: Boolean read FFireTempWorker write FFireTempWorker;

    property IocpEngine: TIocpEngine read FIocpEngine;


  end;

var
  iocpTaskManager: TIocpTaskMananger;

function checkInitializeTaskManager(pvWorkerCount: Integer = 0;
    pvMaxWorkerCount: Word = 0): Boolean;

procedure checkFreeData(var pvData: Pointer; pvDataFreeType: TDataFreeType);

implementation

var
  /// iocpRequestPool
  requestPool:TBaseQueue;

resourcestring
  strDebugRequest_State = 'runInMainThread: %s, done: %s, time(ms): %d';
  strSignalAlreadyRegisted = 'signal(%d) aready registed';
  strSignalUnRegister = 'signal(%d) unregister';

procedure checkFreeData(var pvData: Pointer; pvDataFreeType: TDataFreeType);
begin
  if pvData = nil then exit;
  if pvDataFreeType = ftNone then exit;
  if pvDataFreeType = ftFreeAsObject then
  begin
    TObject(pvData).Free;
  end else if pvDataFreeType = ftUseDispose then
  begin
    Dispose(pvData);
  end;
end;

function MakeTaskProc(const pvData: Pointer; const AProc: TOnTaskWorkProc):
    TOnTaskWork;
begin
  TMethod(Result).Data:=pvData;
  TMethod(Result).Code:=@AProc;
end;
  

function checkInitializeTaskManager(pvWorkerCount: Integer = 0;
    pvMaxWorkerCount: Word = 0): Boolean;
begin
  if iocpTaskManager = nil then
  begin
    iocpTaskManager := TIocpTaskMananger.Create;
    if pvWorkerCount <> 0 then
    begin
      iocpTaskManager.setWorkerCount(pvWorkerCount);
    end;
    if pvMaxWorkerCount = 0 then
    begin
      iocpTaskManager.IocpEngine.setMaxWorkerCount(5);
    end else
    begin
      iocpTaskManager.IocpEngine.setMaxWorkerCount(pvMaxWorkerCount);
    end;

    iocpTaskManager.IocpEngine.Name := 'iocpDefaultTaskManager';
    iocpTaskManager.Active := True;
    Result := true;
  end else
  begin
    Result := false;
  end;
end;



constructor TIocpTaskMananger.Create;
begin
  inherited Create;
  FLocker := TIocpLocker.Create('iocpTaskLocker');
  FIocpEngine := TIocpEngine.Create();
  FIocpEngine.setWorkerCount(2);
  FSignalTasks := TDHashTable.Create(17);
  FSignalTasks.OnDelete := OnSignalTaskDelete;

  FMessageHandle := AllocateHWnd(DoMainThreadWork);
  FFireTempWorker := True;
  FActive := false;
end;

destructor TIocpTaskMananger.Destroy;
begin
  FIocpEngine.safeStop;
  FIocpEngine.Free;

  FSignalTasks.Clear;

  FSignalTasks.Free;
  DeallocateHWnd(FMessageHandle);
  FLocker.Free;
  inherited Destroy;
end;

procedure TIocpTaskMananger.DoMainThreadWork(var AMsg: TMessage);
begin
  if AMsg.Msg = WM_REQUEST_TASK then
  begin
    try
      if not FEnable then Exit;
      TIocpTaskRequest(AMsg.WPARAM).InnerDoTask();
    finally
      if AMsg.LPARAM <> 0 then
        TEvent(AMsg.LPARAM).SetEvent;
    end;
  end else
    AMsg.Result := DefWindowProc(FMessageHandle, AMsg.Msg, AMsg.WPARAM, AMsg.LPARAM);
end;

function TIocpTaskMananger.getStateINfo: String;
var
  lvDebugINfo:TStrings;
begin
  lvDebugINfo := TStringList.Create;
  try
    lvDebugINfo.Add(Format('post counter:%d', [self.FPostCounter]));
    lvDebugINfo.Add(Format('response counter:%d', [self.FResponseCounter]));
    lvDebugINfo.Add(Format('error counter:%d', [self.FErrorCounter]));
    lvDebugINfo.Add('');

    FIocpEngine.writeStateINfo(lvDebugINfo);

    Result := lvDebugINfo.Text;
  finally
    lvDebugINfo.Free;
  end;
end;

procedure TIocpTaskMananger.incErrorCounter;
begin
  InterlockedIncrement(FErrorCounter);
end;

procedure TIocpTaskMananger.incResponseCounter;
begin
  InterlockedIncrement(FResponseCounter);
end;

procedure TIocpTaskMananger.InnerPostTask(pvRequest: TIocpTaskRequest);
begin
  IocpEngine.checkCreateWorker(FFireTempWorker);

  /// post request to iocp queue
  if not IocpEngine.IocpCore.postRequest(0, POverlapped(@pvRequest.FOverlapped)) then
  begin
    RaiseLastOSError;
  end else
  begin
    InterlockedIncrement(FPostCounter);
  end;
end;

procedure TIocpTaskMananger.OnSignalTaskDelete(PHashData: Pointer);
begin
  if PHashData <> nil then
  begin
    TSignalTaskData(PHashData).Free;
  end;
end;

procedure TIocpTaskMananger.PostATask(pvTaskWorkProc: TOnTaskWorkProc;
    pvTaskData: Pointer = nil; pvRunInMainThread: Boolean = False; pvRunType:
    TRunInMainThreadType = rtSync);
var
  lvRequest:TIocpTaskRequest;
begin
  if not FEnable then Exit;
  lvRequest := TIocpTaskRequest(requestPool.DeQueue);
  try
    if lvRequest = nil then
    begin
      lvRequest := TIocpTaskRequest.Create;
    end;
    lvRequest.DoCleanUp;
    lvRequest.FOwner := self;
    lvRequest.FOnTaskWorkProc := pvTaskWorkProc;
    lvRequest.FTaskData := pvTaskData;
    lvRequest.FRunInMainThread := pvRunInMainThread;
    lvRequest.FRunInMainThreadType := pvRunType;

    InnerPostTask(lvRequest);
  except
    // if occur exception, push to requestPool.
    if lvRequest <> nil then requestPool.EnQueue(lvRequest);
    raise;
  end;
end;

procedure TIocpTaskMananger.registerSignal(pvSignalID: Integer; pvTaskWork:
    TOnTaskWork);
var
  lvSignalData:TSignalTaskData;
begin
  Assert(Assigned(pvTaskWork));

  FLocker.lock();
  try
    if FSignalTasks.FindFirst(pvSignalID) <> nil then
      raise Exception.CreateFmt(strSignalAlreadyRegisted, [pvSignalID]);

    lvSignalData := TSignalTaskData.Create;
    lvSignalData.FOnTaskWork := pvTaskWork;
    lvSignalData.FSignalID := pvSignalID;
    FSignalTasks.Add(pvSignalID, lvSignalData);
  finally
    FLocker.unLock;
  end;
end;

procedure TIocpTaskMananger.PostATask(pvTaskWork: TOnTaskWork;
  pvStrData: string; pvRunInMainThread: Boolean;
  pvRunType: TRunInMainThreadType);
var
  lvRequest:TIocpTaskRequest;
begin
  if not FEnable then Exit;
  lvRequest := TIocpTaskRequest(requestPool.DeQueue);
  try
    if lvRequest = nil then
    begin
      lvRequest := TIocpTaskRequest.Create;
    end;
    lvRequest.DoCleanUp;
    lvRequest.FOwner := self;
    lvRequest.FOnTaskWork := pvTaskWork;
    lvRequest.FStrData := pvStrData;
    lvRequest.FRunInMainThread := pvRunInMainThread;
    lvRequest.FRunInMainThreadType := pvRunType;

    InnerPostTask(lvRequest);
  except
    // if occur exception, push to requestPool.
    if lvRequest <> nil then requestPool.EnQueue(lvRequest);
    raise;
  end;

end;

procedure TIocpTaskMananger.PostATask(pvTaskWork:TOnTaskWorkStrData;
    pvStrData:string; pvRunInMainThread:Boolean = False;
    pvRunType:TRunInMainThreadType = rtSync);
var
  lvRequest:TIocpTaskRequest;
begin
  if not FEnable then Exit;
  lvRequest := TIocpTaskRequest(requestPool.DeQueue);
  try
    if lvRequest = nil then
    begin
      lvRequest := TIocpTaskRequest.Create;
    end;
    lvRequest.DoCleanUp;

    lvRequest.FOwner := self;
    lvRequest.FOnTaskWorkStrData := pvTaskWork;
    lvRequest.FStrData := pvStrData;
    lvRequest.FRunInMainThread := pvRunInMainThread;
    lvRequest.FRunInMainThreadType := pvRunType;

    InnerPostTask(lvRequest);
  except
    // if occur exception, push to requestPool.
    if lvRequest <> nil then requestPool.EnQueue(lvRequest);
    raise;
  end;

end;

procedure TIocpTaskMananger.PostATask(pvTaskWork: TOnTaskWork;
  pvTaskData: Pointer; pvRunInMainThread: Boolean;
  pvRunType: TRunInMainThreadType);
var
  lvRequest:TIocpTaskRequest;
begin
  if not FEnable then Exit;
  
  lvRequest := TIocpTaskRequest(requestPool.DeQueue);
  try
    if lvRequest = nil then
    begin
      lvRequest := TIocpTaskRequest.Create;
    end;
    lvRequest.DoCleanUp;

    lvRequest.FOwner := self;
    lvRequest.FOnTaskWork := pvTaskWork;
    lvRequest.FTaskData := pvTaskData;
    lvRequest.FRunInMainThread := pvRunInMainThread;
    lvRequest.FRunInMainThreadType := pvRunType;

    InnerPostTask(lvRequest);
  except
    // if occur exception, push to requestPool.
    if lvRequest <> nil then requestPool.EnQueue(lvRequest);
    raise;
  end;
end;

procedure TIocpTaskMananger.PostATask(pvTaskWork:TOnTaskWorkNoneData;
    pvRunInMainThread:Boolean = False; pvRunType:TRunInMainThreadType = rtSync);
var
  lvRequest:TIocpTaskRequest;
begin
  if not FEnable then Exit;
  lvRequest := TIocpTaskRequest(requestPool.DeQueue);
  try
    if lvRequest = nil then
    begin
      lvRequest := TIocpTaskRequest.Create;
    end;
    lvRequest.DoCleanUp;

    lvRequest.FOwner := self;
    lvRequest.FOnTaskWorkNoneData := pvTaskWork;
    lvRequest.FRunInMainThread := pvRunInMainThread;
    lvRequest.FRunInMainThreadType := pvRunType;

    InnerPostTask(lvRequest);

  except
    // if occur exception, push to requestPool.
    if lvRequest <> nil then requestPool.EnQueue(lvRequest);
    raise;
  end;
end;

procedure TIocpTaskMananger.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    if Value then
    begin
      FIocpEngine.start;
      FActive := Value;
      FEnable := true;
    end else
    begin
      FActive := Value;
      FIocpEngine.safeStop;
    end;
  end;
end;

procedure TIocpTaskMananger.setWorkerCount(pvCounter: Integer);
begin
  if Active then
  begin
    SetActive(False);
    Sleep(100);
    FIocpEngine.setWorkerCount(pvCounter);

    SetActive(True);
    Sleep(100);
  end else
  begin
    FIocpEngine.setWorkerCount(pvCounter);
  end;


end;

procedure TIocpTaskMananger.SignalATask(pvSignalID: Integer; pvTaskData:
    Pointer = nil; pvDataFreeType: TDataFreeType = ftNone; pvRunInMainThread:
    Boolean = False; pvRunType: TRunInMainThreadType = rtSync);
var
  lvSignalData:TSignalTaskData;

  lvRequest:TIocpTaskRequest;
  lvTaskWork: TOnTaskWork;
begin
  lvTaskWork := nil;
  if not FEnable then
  begin
    checkFreeData(pvTaskData, pvDataFreeType);
    exit;
  end;


  FLocker.lock();
  try
    lvSignalData := TSignalTaskData(FSignalTasks.FindFirstData(pvSignalID));
    if lvSignalData = nil then
    begin
      checkFreeData(pvTaskData, pvDataFreeType);
      raise Exception.CreateFmt(strSignalUnRegister, [pvSignalID]);
    end;

    lvTaskWork := lvSignalData.FOnTaskWork;
  finally
    FLocker.unLock;
  end;

  lvRequest := TIocpTaskRequest(requestPool.DeQueue);
  try
    if lvRequest = nil then
    begin
      lvRequest := TIocpTaskRequest.Create;
    end;
    lvRequest.DoCleanUp;
    lvRequest.FFreeType := pvDataFreeType;
    lvRequest.FOwner := self;
    lvRequest.FOnTaskWork := lvTaskWork;
    lvRequest.FTaskData := pvTaskData;
    lvRequest.FRunInMainThread := pvRunInMainThread;
    lvRequest.FRunInMainThreadType := pvRunType;

    InnerPostTask(lvRequest);
  except
    // if occur exception, push to requestPool.
    if lvRequest <> nil then requestPool.EnQueue(lvRequest);

    checkFreeData(pvTaskData, pvDataFreeType);
    raise;
  end;
end;

function TIocpTaskMananger.UnregisterSignal(pvSignalID:Integer): Boolean;
begin
  FLocker.lock();
  try
    Result := FSignalTasks.DeleteFirst(pvSignalID);
  finally
    FLocker.unLock;
  end;
end;

constructor TIocpTaskRequest.Create;
begin
  inherited Create;
  FMessageEvent := TEvent.Create(nil, true, False, '');
end;

destructor TIocpTaskRequest.Destroy;
begin
  FreeAndNil(FMessageEvent);
  inherited Destroy;
end;

{ TIocpTaskRequest }

procedure TIocpTaskRequest.DoCleanUp;
begin
  self.Remark := '';
  FOnTaskWork := nil;
  FRunInMainThreadType := rtSync;
  FMessageEvent.ResetEvent;
  FOwner := nil;
  FFreeType := ftNone;
end;

function TIocpTaskRequest.GetStateINfo: String;
var
  lvEndTime:Cardinal;
begin
  if FEndTime <> 0 then lvEndTime := FEndTime else lvEndTime := GetTickCount;
  Result := '';
  if Remark <> '' then
  begin
    Result := Remark + sLineBreak;
  end;

  Result := Result + Format(strDebugRequest_State, [BoolToStr(FRunInMainThread, True),
    BoolToStr(FEndTime <> 0, True), lvEndTime - FEndTime]);
end;

procedure TIocpTaskRequest.HandleResponse;
begin
  try
    FStartTime := GetTickCount;
    FEndTime := 0;
    FOwner.incResponseCounter;
    if FOwner.Active then
    begin
      if FRunInMainThread then
      begin
        case FRunInMainThreadType of
          rtSync:
            begin
              iocpWorker.Synchronize(iocpWorker, InnerDoTask);
            end;
          rtPostMessage:
            begin
              FMessageEvent.ResetEvent;
              if PostMessage(FOwner.FMessageHandle, WM_REQUEST_TASK, WPARAM(Self), LPARAM(FMessageEvent)) then
              begin
                FMessageEvent.WaitFor(INFINITE);
              end else
              begin
                FOwner.incErrorCounter;
                // log exception
              end;
            end;
          else
            begin
              //log unkown type
            end;
        end;
      end else
      begin
        try
          InnerDoTask;
        except
        end;
      end;
    end;
    FEndTime := GetTickCount;
  finally
    checkFreeData(FTaskData, FFreeType);
    requestPool.EnQueue(Self);
  end;
end;

procedure TIocpTaskRequest.InnerDoTask;
begin

  if Assigned(FOnTaskWork) then
  begin
    FOnTaskWork(Self);
  end else if Assigned(FOnTaskWorkProc) then
  begin
    FOnTaskWorkProc(Self);
  end else if Assigned(FOnTaskWorkStrData) then
  begin
    FOnTaskWorkStrData(FStrData);
  end else if Assigned(FOnTaskWorkNoneData) then
  begin
    FOnTaskWorkNoneData();
  end;

end;

constructor TSimpleDataObject.Create(const ADataString1: String; const
    ADataString2: String = ''; AIntValue1: Integer = 0; AIntValue2: Integer =
    0);
begin
  inherited Create;
  FDataString1 := ADataString1;
  FDataString2 := ADataString2;
  FIntValue1 := AIntValue1;
  FIntValue2 := AIntValue2;
end;



initialization
  requestPool := TBaseQueue.Create;
  requestPool.Name := 'taskRequestPool';
  checkInitializeTaskManager(2);


finalization
  if iocpTaskManager <> nil then
  begin
    iocpTaskManager.Free;
  end;
  requestPool.freeDataObject;
  requestPool.Free;



end.

