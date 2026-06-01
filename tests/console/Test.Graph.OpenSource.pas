unit Test.Graph.OpenSource;

{ Tests for the F7 open-in-IDE named-pipe client (DragLint.Graph.OpenSourceClient).

  Two layers:
    1. BuildOpenSourceMessage -- byte-exact wire framing (deterministic, the
       contract guard the plugin author relies on).
    2. SendOpenSource -- a live round-trip against a byte-mode named-pipe
       server thread that mimics the plugin.  Defensive timeouts ensure the
       test can never hang the suite even if the client fails to connect. }

interface

implementation

uses
  System.SysUtils, System.Classes, Winapi.Windows,
  DragLint.Graph.TestFramework,
  DragLint.Graph.OpenSourceClient;

{ ---- 1. byte-exact framing ---- }

procedure Test_BuildMessage_Framing;
var
  Bytes:    TBytes;
  Expected: TBytes;
  S:        string;
begin
  S := 'C:\Projects\Foo\Bar.pas' + #9 + '128' + #10;
  Expected := TEncoding.UTF8.GetBytes(S);
  Bytes := BuildOpenSourceMessage('C:\Projects\Foo\Bar.pas', 128);

  CheckEqualsInt(Length(Expected), Length(Bytes), 'message byte length');
  Check(Length(Bytes) > 0, 'message is non-empty');
  if Length(Bytes) = Length(Expected) then
    Check(CompareMem(@Bytes[0], @Expected[0], Length(Bytes)),
      'message bytes match <file><TAB><line><LF>');
  { last byte must be the LF terminator, separator must be TAB }
  Check(Bytes[High(Bytes)] = Ord(#10), 'terminated by LF');
end;

procedure Test_BuildMessage_PathWithSpaces;
var
  Bytes: TBytes;
  Got:   string;
begin
  Bytes := BuildOpenSourceMessage('C:\Program Files\App\My Unit.pas', 7);
  Got := TEncoding.UTF8.GetString(Bytes);
  CheckEqualsStr('C:\Program Files\App\My Unit.pas' + #9 + '7' + #10, Got,
    'spaces in path survive framing');
end;

procedure Test_BuildMessage_WithColumn;
var
  Bytes: TBytes;
  Got:   string;
begin
  { contract v2: <file><TAB><line><TAB><col><LF> }
  Bytes := BuildOpenSourceMessage('C:\Foo\Bar.pas', 128, 11);
  Got := TEncoding.UTF8.GetString(Bytes);
  CheckEqualsStr('C:\Foo\Bar.pas' + #9 + '128' + #9 + '11' + #10, Got,
    'column field framed as 3rd TAB-separated value');

  { col <= 0 is normalised to 1 so the plugin always gets a valid column }
  Bytes := BuildOpenSourceMessage('C:\Foo\Bar.pas', 128, 0);
  Got := TEncoding.UTF8.GetString(Bytes);
  CheckEqualsStr('C:\Foo\Bar.pas' + #9 + '128' + #9 + '1' + #10, Got,
    'non-positive column normalised to 1');
end;

{ ---- 2. live round-trip ---- }

type
  TPipeServerThread = class(TThread)
  private
    FPipe:       THandle;
    FReady:      THandle;     { signalled once the pipe instance exists }
    FReceived:   string;
    FGotMessage: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AReady: THandle);
    procedure AbortServer;
    property Received: string read FReceived;
    property GotMessage: Boolean read FGotMessage;
  end;

constructor TPipeServerThread.Create(AReady: THandle);
begin
  FReady      := AReady;
  FPipe       := INVALID_HANDLE_VALUE;
  FGotMessage := False;
  inherited Create(False);
end;

procedure TPipeServerThread.AbortServer;
begin
  { Unblock a stuck ConnectNamedPipe/ReadFile by closing the handle. }
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  FPipe := INVALID_HANDLE_VALUE;
end;

procedure TPipeServerThread.Execute;
var
  Buf:     array[0..1023] of Byte;
  Read:    DWORD;
  Acc:     TBytes;
  Connected: Boolean;
begin
  FPipe := CreateNamedPipe(OPEN_SOURCE_PIPE_NAME,
    PIPE_ACCESS_INBOUND,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
    1, 0, SizeOf(Buf), 0, nil);
  { Signal "pipe exists" regardless, so the main thread proceeds and (on
    failure) can abort us. }
  SetEvent(FReady);
  if FPipe = INVALID_HANDLE_VALUE then Exit;

  Connected := ConnectNamedPipe(FPipe, nil);
  if (not Connected) and (GetLastError <> ERROR_PIPE_CONNECTED) then Exit;

  SetLength(Acc, 0);
  while ReadFile(FPipe, Buf[0], SizeOf(Buf), Read, nil) and (Read > 0) do
  begin
    SetLength(Acc, Length(Acc) + Integer(Read));
    Move(Buf[0], Acc[Length(Acc) - Integer(Read)], Read);
    if Acc[High(Acc)] = Ord(#10) then Break;   { LF = end of message }
  end;

  if Length(Acc) > 0 then
  begin
    FReceived   := TEncoding.UTF8.GetString(Acc);
    FGotMessage := True;
  end;

  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  FPipe := INVALID_HANDLE_VALUE;
end;

procedure Test_SendOpenSource_RoundTrip;
const
  EXPECTED_FILE = 'C:\Projects\DB\ORM3\Some.Unit.pas';
  EXPECTED_LINE = 4242;
var
  Ready:  THandle;
  Server: TPipeServerThread;
  Ok:     Boolean;
begin
  Ready  := CreateEvent(nil, True, False, nil);
  Server := TPipeServerThread.Create(Ready);
  try
    { Wait until the server has created the pipe instance (or 2s guard). }
    if WaitForSingleObject(Ready, 2000) <> WAIT_OBJECT_0 then
    begin
      Check(False, 'pipe server failed to come up');
      Server.AbortServer;
      Exit;
    end;

    Ok := SendOpenSource(EXPECTED_FILE, EXPECTED_LINE, 1000);
    Check(Ok, 'SendOpenSource reports success against a live server');

    { Let the server finish reading; abort if it stalls so we never hang. }
    if WaitForSingleObject(Server.Handle, 3000) <> WAIT_OBJECT_0 then
    begin
      Server.AbortServer;
      WaitForSingleObject(Server.Handle, 1000);
      Check(False, 'pipe server did not finish in time');
    end
    else
    begin
      Check(Server.GotMessage, 'server received a message');
      CheckEqualsStr(EXPECTED_FILE + #9 + IntToStr(EXPECTED_LINE) + #10,
        Server.Received, 'round-tripped message matches what was sent');
    end;
  finally
    Server.WaitFor;
    Server.Free;
    CloseHandle(Ready);
  end;
end;

procedure Test_SendOpenSource_NoServer;
var
  Ok: Boolean;
begin
  { With no server listening, the client must fail fast (within the wait
    window) so the host can fall back to ShellExecute -- it must NOT block or
    raise. }
  Ok := SendOpenSource('C:\nope\missing.pas', 1, 200);
  Check(not Ok, 'SendOpenSource returns False when no plugin is listening');
end;

procedure Test_SendOpenSource_EmptyFile;
begin
  Check(not SendOpenSource('', 10, 100), 'empty file path is rejected');
end;

initialization
  RegisterTest('OpenSource_BuildMessage_Framing', Test_BuildMessage_Framing);
  RegisterTest('OpenSource_BuildMessage_PathWithSpaces', Test_BuildMessage_PathWithSpaces);
  RegisterTest('OpenSource_BuildMessage_WithColumn', Test_BuildMessage_WithColumn);
  RegisterTest('OpenSource_SendOpenSource_NoServer', Test_SendOpenSource_NoServer);
  RegisterTest('OpenSource_SendOpenSource_EmptyFile', Test_SendOpenSource_EmptyFile);
  RegisterTest('OpenSource_SendOpenSource_RoundTrip', Test_SendOpenSource_RoundTrip);
end.
