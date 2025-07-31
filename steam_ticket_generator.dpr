program steam_ticket_generator;

{$WEAKLINKRTTI ON}
{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}

{$APPTYPE CONSOLE}

{$R *.res}

uses
  Windows, System.SysUtils, System.Classes, System.NetEncoding;

{$SETPEFLAGS IMAGE_FILE_RELOCS_STRIPPED}

function SteamAPI_InitFlat(pCallback: Pointer): Integer; external 'steam_api64.dll';
procedure SteamAPI_ManualDispatch_Init; external 'steam_api64.dll';
function SteamAPI_SteamUser_v023: Pointer; external 'steam_api64.dll';
function SteamAPI_ISteamUser_RequestEncryptedAppTicket(user: Pointer; data: Pointer; len: Cardinal): Boolean; external 'steam_api64.dll';
function SteamAPI_GetHSteamPipe: Integer; external 'steam_api64.dll';
procedure SteamAPI_ManualDispatch_RunFrame(hPipe: Integer); external 'steam_api64.dll';
function SteamAPI_ManualDispatch_GetNextCallback(hPipe: Integer; callback: Pointer): Boolean; external 'steam_api64.dll';
procedure SteamAPI_ManualDispatch_FreeLastCallback(hPipe: Integer); external 'steam_api64.dll';
function SteamAPI_ManualDispatch_GetAPICallResult(hPipe: Integer; call: UInt64; buffer: Pointer; bufferSize: Cardinal; callbackType: Integer; failed: PBool): Boolean; external 'steam_api64.dll';
function SteamAPI_ISteamUser_GetEncryptedAppTicket(user: Pointer; buffer: Pointer; size: Cardinal; var length: Cardinal): Boolean; external 'steam_api64.dll';
function SteamAPI_ISteamUser_GetSteamID(user: Pointer): UInt64; external 'steam_api64.dll';
function SteamAPI_SteamFriends_v018: Pointer; external 'steam_api64.dll';
function SteamAPI_ISteamFriends_GetPersonaName(friends: Pointer): PAnsiChar; external 'steam_api64.dll';

const
  k_ESteamAPIInitResult_FailedGeneric = 1;
  k_ESteamAPIInitResult_NoSteamClient = 2;
  EncryptedAppTicketResponse_t_k_iCallback = 154;
  SteamAPICallCompleted_t_k_iCallback = 703;

type
  TSteamCallback = packed record
    m_iCallback: Integer;
    m_pubParam: Pointer;
    m_cubParam: Integer;
  end;
  TSteamAPICallCompleted = packed record
    m_hAsyncCall: UInt64;
    m_iCallback: Integer;
    m_cubParam: Integer;
  end;
  TEncryptedAppTicketResponse = packed record
    m_eResult: Integer;
  end;

function RunCallbacks(pipe: Integer): Integer;
var
  callback: TSteamCallback;
  completed: ^TSteamAPICallCompleted;
  ticketResp: ^TEncryptedAppTicketResponse;
  failed: Boolean;
  buffer: TBytes;
begin
  Result := -1;
  FillChar(callback, SizeOf(callback), 0);
  SteamAPI_ManualDispatch_RunFrame(pipe);
  while SteamAPI_ManualDispatch_GetNextCallback(pipe, @callback) do begin
    if callback.m_iCallback = SteamAPICallCompleted_t_k_iCallback then begin
      completed := callback.m_pubParam;
      SetLength(buffer, completed.m_cubParam);
      if SteamAPI_ManualDispatch_GetAPICallResult(pipe, completed.m_hAsyncCall, @buffer[0], completed.m_cubParam, completed.m_iCallback, @failed) then begin
        if not failed and (completed.m_iCallback = EncryptedAppTicketResponse_t_k_iCallback) then begin
          ticketResp := Pointer(@buffer[0]);
          Result := ticketResp.m_eResult;
        end;
      end;
    end;
    SteamAPI_ManualDispatch_FreeLastCallback(pipe);
  end;
end;

procedure CreateConfig(SteamID: UInt64; const Ticket, PersonaName: string);
var
  StringList1: TStringList;
begin
  StringList1:=TStringList.Create;
  try
    StringList1.WriteBOM := False;
    StringList1.Append('[user::general]');
    StringList1.Append('account_name=' + PersonaName);
    StringList1.Append('account_steamid=' + UIntToStr(SteamID));
    StringList1.Append('language=english');
    StringList1.Append('ip_country=US');
    StringList1.Append('ticket=' + Ticket);
    StringList1.Append('');
    StringList1.Append('[user::saves]');
    StringList1.Append('saves_folder_name=GSE Saves');
    StringList1.SaveToFile('configs.user.ini', TEncoding.UTF8);
  finally StringList1.Free end;
end;

procedure GenerateTicket(appId: Integer);
var
  User: Pointer;
  Ticket: TBytes;
  TicketLen: Cardinal;
  SteamID: UInt64;
  InitResult, Pipe, Res, Retry: Integer;
  s, EncodedTicket: string;
begin
  SetEnvironmentVariable('SteamAppId', PChar(appId.ToString));
  SetEnvironmentVariable('SteamGameId', PChar(appId.ToString));

  InitResult := SteamAPI_InitFlat(nil);
  SteamAPI_ManualDispatch_Init;

  case InitResult of
    k_ESteamAPIInitResult_FailedGeneric: raise Exception.Create('Failed to initialize Steam API');
    k_ESteamAPIInitResult_NoSteamClient: raise Exception.Create('Steam client is not running');
  end;

  User := SteamAPI_SteamUser_v023;
  SteamAPI_ISteamUser_RequestEncryptedAppTicket(User, nil, 0);

  Pipe := SteamAPI_GetHSteamPipe;

  for Retry := 0 to 99 do begin
    Res := RunCallbacks(Pipe);
    if (Res >= 0) then begin
      if (Res <> 1) then raise Exception.CreateFmt('Failed to get encrypted app ticket, error code: %d', [Res]);
      Break;
    end;
    Sleep(100);
  end;

  SetLength(Ticket, 2048);
  TicketLen := 0;

  if not SteamAPI_ISteamUser_GetEncryptedAppTicket(User, @Ticket[0], 2048, TicketLen) then
    raise Exception.Create('Failed to get encrypted app ticket. Does the account own the game?');

  SetLength(Ticket, TicketLen);
  EncodedTicket := StringReplace(StringReplace(TNetEncoding.Base64.EncodeBytesToString(Ticket), #13, '', [rfReplaceAll]), #10, '', [rfReplaceAll]);

  SteamID := SteamAPI_ISteamUser_GetSteamID(User);
  Writeln('Steam ID: ', SteamID);
  Writeln('Encrypted App Ticket: ', EncodedTicket);

  Writeln('Create configs.user.ini file? [Y/N]');
  Readln(s);
  if (Trim(LowerCase(s)) = 'y') then begin
    CreateConfig(SteamID, EncodedTicket, String(UTF8ToString(SteamAPI_ISteamFriends_GetPersonaName(SteamAPI_SteamFriends_v018))));
    Writeln('configs.user.ini created successfully.');
  end;
end;

procedure Main;
var
  AppID: Integer;
  AppIDStr: string;
begin
  Write('Enter the App ID: ');
  Readln(AppIDStr);
  AppID := StrToIntDef(AppIDStr, 0);
  try
    GenerateTicket(AppID);
  except on E: Exception do begin
    Writeln('Error while generating ticket: ', E.Message);
    Writeln('Make sure Steam is running and you own the game.');
  end end;
  Writeln('Press Enter to exit...');
  Readln;
end;

begin
  Main;
end.

