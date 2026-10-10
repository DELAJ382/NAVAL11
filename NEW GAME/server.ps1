$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public sealed class OutlandPeer
{
    public string Id;
    public string Room;
    public string Name;
    public string Email;
    public string Mode;
    public string DropSite;
    public string Weapon = "rifle";
    public string Color = "#687d53";
    public int Team = -1;
    public double X;
    public double Z;
    public double Y;
    public double Yaw;
    public int Health = 100;
    public DateTime LastHit = DateTime.MinValue;
    public DateTime LastDamage = DateTime.MinValue;
    public WebSocket Socket;
    public readonly SemaphoreSlim SendGate = new SemaphoreSlim(1, 1);
}

public sealed class OutlandAccount
{
    public string Uid { get; set; }
    public string Email { get; set; }
    public string Name { get; set; }
    public DateTime VerifiedAt { get; set; }
}

public sealed class OutlandRoomHost
{
    private readonly string root;
    private readonly string prefix;
    private readonly HttpListener listener = new HttpListener();
    private readonly JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = 16384 };
    private readonly ConcurrentDictionary<string, ConcurrentDictionary<string, OutlandPeer>> rooms = new ConcurrentDictionary<string, ConcurrentDictionary<string, OutlandPeer>>();
    private readonly ConcurrentDictionary<string, OutlandAccount> verifiedTokens = new ConcurrentDictionary<string, OutlandAccount>();
    private readonly string firebaseBaseUrl = "https://naval-27f95-default-rtdb.firebaseio.com";
    private readonly string firebaseApiKey = "AIzaSyBse_PdnkEHM6ysPqXWgF-Y3sGETbM4GX0";
    private readonly HttpClient firebaseClient = new HttpClient();
    private readonly object firebaseTokenGate = new object();
    private string firebaseAccessToken;
    private DateTime firebaseTokenExpiresAt = DateTime.MinValue;

    public OutlandRoomHost(string root, string prefix)
    {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        firebaseClient.Timeout = TimeSpan.FromSeconds(20);
        this.root = root;
        this.prefix = prefix;
        listener.Prefixes.Add(prefix);
    }

    public async Task RunAsync()
    {
        listener.Start();
        Console.WriteLine("OUTLAND multiplayer server is listening at " + prefix);
        while (listener.IsListening)
        {
            HttpListenerContext context = await listener.GetContextAsync().ConfigureAwait(false);
            Task ignored = HandleAsync(context);
        }
    }

    private async Task HandleAsync(HttpListenerContext context)
    {
        try
        {
            if (!context.Request.IsWebSocketRequest)
            {
                string path = context.Request.Url.AbsolutePath;
                if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
                {
                    string origin = context.Request.Headers["Origin"];
                    string allowedOrigin = Environment.GetEnvironmentVariable("OUTLAND_ALLOWED_ORIGIN");
                    if (!String.IsNullOrWhiteSpace(origin) &&
                        origin.Equals(allowedOrigin, StringComparison.OrdinalIgnoreCase))
                    {
                        context.Response.Headers["Access-Control-Allow-Origin"] = allowedOrigin;
                        context.Response.Headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
                        context.Response.Headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization";
                        context.Response.Headers["Vary"] = "Origin";
                    }
                    if (context.Request.HttpMethod == "OPTIONS")
                    {
                        if (String.IsNullOrWhiteSpace(origin) ||
                            !origin.Equals(allowedOrigin, StringComparison.OrdinalIgnoreCase))
                        {
                            await WriteResponse(context, 403, "text/plain", Encoding.UTF8.GetBytes("Origin is not allowed."));
                            return;
                        }
                        context.Response.StatusCode = 204;
                        context.Response.ContentLength64 = 0;
                        context.Response.Close();
                        return;
                    }
                    await HandleApiAsync(context).ConfigureAwait(false);
                    return;
                }
                if (path == "/health")
                {
                    await WriteResponse(context, 200, "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}"));
                    return;
                }
                if (path != "/" && !path.Equals("/index.html", StringComparison.OrdinalIgnoreCase))
                {
                    await WriteResponse(context, 404, "text/plain", Encoding.UTF8.GetBytes("Not found"));
                    return;
                }
                byte[] page = File.ReadAllBytes(Path.Combine(root, "index.html"));
                await WriteResponse(context, 200, "text/html; charset=utf-8", page);
                return;
            }

            HttpListenerWebSocketContext accepted = await context.AcceptWebSocketAsync(null).ConfigureAwait(false);
            OutlandPeer peer = new OutlandPeer { Socket = accepted.WebSocket };
            await ReceiveLoop(peer).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            Console.WriteLine("Request ended: " + error.Message);
            try { context.Response.Close(); } catch { }
        }
    }

    private static async Task WriteResponse(HttpListenerContext context, int status, string contentType, byte[] body)
    {
        context.Response.StatusCode = status;
        context.Response.ContentType = contentType;
        context.Response.ContentLength64 = body.Length;
        context.Response.Headers["Cache-Control"] = "no-store";
        await context.Response.OutputStream.WriteAsync(body, 0, body.Length).ConfigureAwait(false);
        context.Response.Close();
    }

    private async Task WriteJsonResponse(HttpListenerContext context, int status, object value)
    {
        byte[] body = Encoding.UTF8.GetBytes(serializer.Serialize(value));
        await WriteResponse(context, status, "application/json; charset=utf-8", body).ConfigureAwait(false);
    }

    private static string AccountDatabaseKey(string email)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(email.ToLowerInvariant()))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static byte[] ReadDerValue(byte[] data, ref int offset, byte expectedTag)
    {
        if (offset >= data.Length || data[offset++] != expectedTag)
            throw new InvalidDataException("Invalid service-account private key.");
        if (offset >= data.Length) throw new InvalidDataException("Invalid service-account private key.");
        int length = data[offset++];
        if ((length & 0x80) != 0)
        {
            int lengthBytes = length & 0x7f;
            if (lengthBytes == 0 || lengthBytes > 4 || offset + lengthBytes > data.Length)
                throw new InvalidDataException("Invalid service-account private key.");
            length = 0;
            for (int i = 0; i < lengthBytes; i++) length = (length << 8) | data[offset++];
        }
        if (length < 0 || offset + length > data.Length)
            throw new InvalidDataException("Invalid service-account private key.");
        byte[] value = new byte[length];
        Buffer.BlockCopy(data, offset, value, 0, length);
        offset += length;
        return value;
    }

    private static byte[] ToBigEndianUnsigned(byte[] value)
    {
        int start = 0;
        while (start < value.Length - 1 && value[start] == 0) start++;
        byte[] result = new byte[value.Length - start];
        Buffer.BlockCopy(value, start, result, 0, result.Length);
        return result;
    }

    private static RSAParameters ReadRsaParameters(string pem)
    {
        string base64 = Regex.Replace(pem, "-----[^-]+-----|\\s", "");
        byte[] der = Convert.FromBase64String(base64);
        int offset = 0;
        byte[] outer = ReadDerValue(der, ref offset, 0x30);
        offset = 0;
        ReadDerValue(outer, ref offset, 0x02);
        ReadDerValue(outer, ref offset, 0x30);
        byte[] privateKey = ReadDerValue(outer, ref offset, 0x04);
        offset = 0;
        byte[] rsaSequence = ReadDerValue(privateKey, ref offset, 0x30);
        offset = 0;
        ReadDerValue(rsaSequence, ref offset, 0x02);
        return new RSAParameters
        {
            Modulus = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            Exponent = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            D = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            P = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            Q = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            DP = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            DQ = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02)),
            InverseQ = ToBigEndianUnsigned(ReadDerValue(rsaSequence, ref offset, 0x02))
        };
    }

    private static string Base64Url(byte[] value)
    {
        return Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private async Task<string> GetFirebaseAccessTokenAsync()
    {
        lock (firebaseTokenGate)
            if (!String.IsNullOrEmpty(firebaseAccessToken) && DateTime.UtcNow < firebaseTokenExpiresAt)
                return firebaseAccessToken;

        string credentialsPath = Environment.GetEnvironmentVariable("OUTLAND_FIREBASE_SERVICE_ACCOUNT");
        if (String.IsNullOrWhiteSpace(credentialsPath) || !File.Exists(credentialsPath))
            throw new InvalidOperationException("Set OUTLAND_FIREBASE_SERVICE_ACCOUNT to the Firebase service-account JSON file.");

        Dictionary<string, object> credentials = serializer.Deserialize<Dictionary<string, object>>(
            File.ReadAllText(credentialsPath, Encoding.UTF8));
        string clientEmail = Text(credentials, "client_email");
        string privateKey = Text(credentials, "private_key");
        string tokenUri = Text(credentials, "token_uri");
        if (String.IsNullOrWhiteSpace(clientEmail) || String.IsNullOrWhiteSpace(privateKey) ||
            String.IsNullOrWhiteSpace(tokenUri))
            throw new InvalidDataException("Firebase service-account JSON is missing required fields.");

        long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        string header = Base64Url(Encoding.UTF8.GetBytes("{\"alg\":\"RS256\",\"typ\":\"JWT\"}"));
        string claims = serializer.Serialize(new Dictionary<string, object>
        {
            { "iss", clientEmail },
            { "scope", "https://www.googleapis.com/auth/firebase.database https://www.googleapis.com/auth/userinfo.email" },
            { "aud", tokenUri },
            { "iat", now },
            { "exp", now + 3600 }
        });
        string unsignedAssertion = header + "." + Base64Url(Encoding.UTF8.GetBytes(claims));
        string assertion;
        using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider())
        {
            rsa.ImportParameters(ReadRsaParameters(privateKey));
            assertion = unsignedAssertion + "." + Base64Url(
                rsa.SignData(Encoding.UTF8.GetBytes(unsignedAssertion), CryptoConfig.MapNameToOID("SHA256")));
        }

        string form = "grant_type=" + Uri.EscapeDataString("urn:ietf:params:oauth:grant-type:jwt-bearer") +
            "&assertion=" + Uri.EscapeDataString(assertion);
        using (StringContent content = new StringContent(form, Encoding.UTF8, "application/x-www-form-urlencoded"))
        using (HttpResponseMessage response = await firebaseClient.PostAsync(tokenUri, content).ConfigureAwait(false))
        {
            string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException("Google OAuth token request failed: " + response.StatusCode + " " + json);
            Dictionary<string, object> tokenResult = serializer.Deserialize<Dictionary<string, object>>(json);
            string accessToken = Text(tokenResult, "access_token");
            if (String.IsNullOrWhiteSpace(accessToken))
                throw new InvalidDataException("Google OAuth response did not contain an access token.");
            int expiresIn;
            if (!Int32.TryParse(Text(tokenResult, "expires_in"), out expiresIn) || expiresIn <= 60)
                expiresIn = 3600;
            lock (firebaseTokenGate)
            {
                firebaseAccessToken = accessToken;
                firebaseTokenExpiresAt = DateTime.UtcNow.AddSeconds(expiresIn - 60);
            }
            return accessToken;
        }
    }

    private async Task WriteFirebaseRecordAsync(string path, object value)
    {
        string accessToken = await GetFirebaseAccessTokenAsync().ConfigureAwait(false);
        string endpoint = firebaseBaseUrl.TrimEnd('/') + "/" + path +
            ".json?access_token=" + Uri.EscapeDataString(accessToken);
        string payload = serializer.Serialize(value);
        using (StringContent content = new StringContent(payload, Encoding.UTF8, "application/json"))
        using (HttpResponseMessage response = await firebaseClient.PutAsync(endpoint, content).ConfigureAwait(false))
        {
            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException("Firebase database write failed: " + response.StatusCode);
        }
    }

    private async Task<OutlandAccount> VerifyFirebaseIdTokenAsync(string idToken)
    {
        if (String.IsNullOrWhiteSpace(idToken) || idToken.Length > 8192) return null;

        OutlandAccount cached;
        if (verifiedTokens.TryGetValue(idToken, out cached) &&
            DateTime.UtcNow - cached.VerifiedAt < TimeSpan.FromMinutes(5))
            return cached;

        string endpoint = "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=" +
            Uri.EscapeDataString(firebaseApiKey);
        string payload = serializer.Serialize(new Dictionary<string, object> { { "idToken", idToken } });
        using (StringContent content = new StringContent(payload, Encoding.UTF8, "application/json"))
        using (HttpResponseMessage response = await firebaseClient.PostAsync(endpoint, content).ConfigureAwait(false))
        {
            string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            if ((int)response.StatusCode == 400 || (int)response.StatusCode == 401) return null;
            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException("Firebase ID-token verification failed: " + response.StatusCode + " " + json);

            Dictionary<string, object> result = serializer.Deserialize<Dictionary<string, object>>(json);
            object rawUsers;
            ArrayList users = result != null && result.TryGetValue("users", out rawUsers) ? rawUsers as ArrayList : null;
            if (users == null || users.Count == 0) return null;

            Dictionary<string, object> user = users[0] as Dictionary<string, object>;
            if (user == null) return null;
            string uid = Text(user, "localId");
            string email = Text(user, "email").Trim().ToLowerInvariant();
            if (String.IsNullOrWhiteSpace(uid) || String.IsNullOrWhiteSpace(email)) return null;

            OutlandAccount account = new OutlandAccount
            {
                Uid = uid,
                Email = email,
                Name = Text(user, "displayName"),
                VerifiedAt = DateTime.UtcNow
            };
            if (String.IsNullOrWhiteSpace(account.Name)) account.Name = email.Split('@')[0];
            verifiedTokens[idToken] = account;
            foreach (KeyValuePair<string, OutlandAccount> entry in verifiedTokens)
                if (DateTime.UtcNow - entry.Value.VerifiedAt >= TimeSpan.FromMinutes(5))
                {
                    OutlandAccount removed;
                    verifiedTokens.TryRemove(entry.Key, out removed);
                }
            return account;
        }
    }

    private async Task HandleApiAsync(HttpListenerContext context)
    {
        if (context.Request.HttpMethod != "POST")
        {
            await WriteJsonResponse(context, 405, new { error = "POST required." }).ConfigureAwait(false);
            return;
        }
        if (context.Request.ContentLength64 > 8192)
        {
            await WriteJsonResponse(context, 413, new { error = "Request too large." }).ConfigureAwait(false);
            return;
        }

        try
        {
            string body;
            using (MemoryStream stream = new MemoryStream())
            {
                await context.Request.InputStream.CopyToAsync(stream).ConfigureAwait(false);
                if (stream.Length > 8192) throw new InvalidDataException("Request too large.");
                body = Encoding.UTF8.GetString(stream.ToArray());
            }
            Dictionary<string, object> data = serializer.Deserialize<Dictionary<string, object>>(body);
            string path = context.Request.Url.AbsolutePath.ToLowerInvariant();

            if (path == "/api/sync")
            {
                await HandleFirebaseSyncAsync(context, data).ConfigureAwait(false);
                return;
            }

            await WriteJsonResponse(context, 404, new { error = "Unknown account endpoint." }).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            Console.WriteLine("Account request failed: " + error);
            if (!context.Response.OutputStream.CanWrite) return;
        }
        await WriteJsonResponse(context, 500, new { error = "Account service is unavailable." }).ConfigureAwait(false);
    }

    private async Task HandleFirebaseSyncAsync(HttpListenerContext context, Dictionary<string, object> data)
    {
        string authorization = context.Request.Headers["Authorization"] ?? "";
        if (!authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            await WriteJsonResponse(context, 401, new { error = "Sign in is required." }).ConfigureAwait(false);
            return;
        }
        OutlandAccount account;
        Exception authenticationError = null;
        try
        {
            account = await VerifyFirebaseIdTokenAsync(authorization.Substring(7).Trim()).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            authenticationError = error;
            account = null;
        }
        if (authenticationError != null)
        {
            Console.WriteLine("Firebase sync authentication failed: " + authenticationError);
            await WriteJsonResponse(context, 503, new { error = "Firebase authentication is temporarily unavailable." }).ConfigureAwait(false);
            return;
        }
        if (account == null)
        {
            await WriteJsonResponse(context, 401, new { error = "Sign in again to sync your account." }).ConfigureAwait(false);
            return;
        }

        object rawValue;
        if (!data.TryGetValue("value", out rawValue))
        {
            await WriteJsonResponse(context, 400, new { error = "A sync value is required." }).ConfigureAwait(false);
            return;
        }
        Dictionary<string, object> value = rawValue as Dictionary<string, object>;
        if (value == null)
        {
            await WriteJsonResponse(context, 400, new { error = "Invalid sync value." }).ConfigureAwait(false);
            return;
        }

        string type = Text(data, "type");
        if (type == "player")
        {
            string room = Text(value, "room").ToUpperInvariant();
            if (!Regex.IsMatch(room, "^[A-Z0-9_-]{1,12}$"))
                room = "OUTLAND";
            Dictionary<string, object> record = new Dictionary<string, object>
            {
                { "name", account.Name },
                { "email", account.Email },
                { "lastSeen", (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds },
                { "room", room },
                { "mode", Text(value, "mode") },
                { "dropSite", Text(value, "dropSite") },
                { "weapon", Text(value, "weapon") },
                { "color", Text(value, "color") }
            };
            await WriteFirebaseRecordAsync("players/" + AccountDatabaseKey(account.Uid), record).ConfigureAwait(false);
        }
        else if (type == "room")
        {
            string roomName = Text(value, "name").ToUpperInvariant();
            if (!Regex.IsMatch(roomName, "^[A-Z0-9_-]{1,12}$"))
            {
                await WriteJsonResponse(context, 400, new { error = "Invalid room name." }).ConfigureAwait(false);
                return;
            }
            int players;
            if (!Int32.TryParse(Text(value, "players"), out players) || players < 0) players = 0;
            Dictionary<string, object> record = new Dictionary<string, object>
            {
                { "mode", Text(value, "mode") },
                { "dropSite", Text(value, "dropSite") },
                { "updatedAt", (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds },
                { "players", Math.Min(players, 1000) }
            };
            await WriteFirebaseRecordAsync("rooms/" + roomName, record).ConfigureAwait(false);
        }
        else
        {
            await WriteJsonResponse(context, 400, new { error = "Unknown sync type." }).ConfigureAwait(false);
            return;
        }

        await WriteJsonResponse(context, 200, new { ok = true }).ConfigureAwait(false);
    }

    private async Task ReceiveLoop(OutlandPeer peer)
    {
        byte[] buffer = new byte[4096];
        try
        {
            while (peer.Socket.State == WebSocketState.Open)
            {
                using (MemoryStream message = new MemoryStream())
                {
                    WebSocketReceiveResult result;
                    do
                    {
                        result = await peer.Socket.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None).ConfigureAwait(false);
                        if (result.MessageType == WebSocketMessageType.Close) return;
                        message.Write(buffer, 0, result.Count);
                        if (message.Length > 8192) throw new InvalidDataException("Message too large");
                    } while (!result.EndOfMessage);

                    Dictionary<string, object> data = serializer.Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(message.ToArray()));
                    if (data != null) await HandleMessage(peer, data).ConfigureAwait(false);
                }
            }
        }
        catch (Exception error)
        {
            if (peer.Socket.State == WebSocketState.Open) Console.WriteLine("Client ended: " + error.Message);
        }
        finally
        {
            RemovePeer(peer);
            try
            {
                if (peer.Socket.State == WebSocketState.Open || peer.Socket.State == WebSocketState.CloseReceived)
                    peer.Socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Room closed", CancellationToken.None).GetAwaiter().GetResult();
            }
            catch { }
        }
    }

    private async Task HandleMessage(OutlandPeer peer, Dictionary<string, object> data)
    {
        string type = Text(data, "type");
        if (type == "join")
        {
            string roomName = Text(data, "room").ToUpperInvariant();
            if (!Regex.IsMatch(roomName, "^[A-Z0-9_-]{2,12}$")) roomName = "OUTLAND";
            OutlandAccount account;
            Exception authenticationError = null;
            try
            {
                account = await VerifyFirebaseIdTokenAsync(Text(data, "token")).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                authenticationError = error;
                account = null;
            }
            if (authenticationError != null)
            {
                Console.WriteLine("Firebase room authentication failed: " + authenticationError);
                await Send(peer, new { type = "error", message = "Account verification is temporarily unavailable. Try again." });
                return;
            }
            if (account == null)
            {
                await Send(peer, new { type = "error", message = "Sign in with your email to enter a room." });
                return;
            }
            ConcurrentDictionary<string, OutlandPeer> room = rooms.GetOrAdd(roomName, _ => new ConcurrentDictionary<string, OutlandPeer>());
            if (room.Count >= 50)
            {
                await Send(peer, new { type = "error", message = "Room is full (50 operators maximum)." });
                return;
            }

            string mode = Text(data, "mode").ToLowerInvariant();
            if (mode != "teams" && mode != "survival" && mode != "battle-royale") mode = "ffa";
            foreach (OutlandPeer other in room.Values)
            {
                if (other.Mode != mode)
                {
                    string modeName = other.Mode == "teams" ? "TEAM BATTLE" : other.Mode == "survival" ? "SURVIVAL" : other.Mode == "battle-royale" ? "BATTLE ROYALE" : "FREE FOR ALL";
                    await Send(peer, new { type = "error", message = "This room is running " + modeName + ". Choose the same mode or use another room code." });
                    return;
                }
            }

            peer.Id = Guid.NewGuid().ToString("N").Substring(0, 8);
            peer.Room = roomName;
            peer.Name = account.Name;
            peer.Email = account.Email;
            peer.Mode = mode;
            peer.DropSite = NormalizeDropSite(Text(data, "dropSite"));
            peer.Weapon = NormalizeWeapon(Text(data, "weapon"));
            if (mode == "teams")
            {
                int teamZero = 0, teamOne = 0;
                foreach (OutlandPeer other in room.Values)
                    if (other.Team == 0) teamZero++; else if (other.Team == 1) teamOne++;
                peer.Team = teamZero <= teamOne ? 0 : 1;
            }
            int spawnIndex = -1;
            for (int candidate = 0; candidate < 50; candidate++)
            {
                double angle = Math.PI * 2 * candidate / 50;
                double candidateX = DropCenterX(peer.DropSite) + Math.Cos(angle) * 13;
                double candidateZ = DropCenterZ(peer.DropSite) + Math.Sin(angle) * 13;
                bool occupied = false;
                foreach (OutlandPeer other in room.Values)
                {
                    double dx = other.X - candidateX, dz = other.Z - candidateZ;
                    if (other.DropSite == peer.DropSite && dx * dx + dz * dz < 1.44) { occupied = true; break; }
                }
                if (!occupied) { spawnIndex = candidate; peer.X = candidateX; peer.Z = candidateZ; break; }
            }
            if (spawnIndex < 0)
            {
                await Send(peer, new { type = "error", message = "This drop site is full. Choose another region or room." });
                return;
            }
            string color = Text(data, "color");
            if (Regex.IsMatch(color, "^#[0-9a-fA-F]{6}$")) peer.Color = color;
            room[peer.Id] = peer;
            List<object> existing = new List<object>();
            foreach (OutlandPeer other in room.Values)
                if (other.Id != peer.Id) existing.Add(Snapshot(other));
            await Send(peer, new { type = "welcome", id = peer.Id, room = roomName, mode = peer.Mode, team = peer.Team, dropSite = peer.DropSite, dropName = DropSiteName(peer.DropSite), spawnX = peer.X, spawnZ = peer.Z, players = existing });
            await Broadcast(roomName, new { type = "playerJoined", player = Snapshot(peer) }, peer.Id);
            Console.WriteLine(peer.Id + " joined room " + roomName + " (" + room.Count + " operators)");
            return;
        }

        if (String.IsNullOrEmpty(peer.Room)) return;
        if (type == "state")
        {
            peer.X = Number(data, "x", peer.X, -43, 43);
            peer.Z = Number(data, "z", peer.Z, -35, 35);
            peer.Y = Number(data, "y", peer.Y, -1, 40);
            peer.Yaw = Number(data, "yaw", peer.Yaw, -1000, 1000);
            string color = Text(data, "color");
            if (Regex.IsMatch(color, "^#[0-9a-fA-F]{6}$")) peer.Color = color;
            peer.Weapon = NormalizeWeapon(Text(data, "weapon"));
            await Broadcast(peer.Room, new { type = "playerState", player = Snapshot(peer) }, peer.Id);
        }
        else if (type == "shot")
        {
            await Broadcast(peer.Room, new { type = "playerShot", id = peer.Id, from = data.ContainsKey("from") ? data["from"] : null, to = data.ContainsKey("to") ? data["to"] : null }, peer.Id);
        }
        else if (type == "hit")
        {
            string targetId = Text(data, "targetId");
            ConcurrentDictionary<string, OutlandPeer> room;
            OutlandPeer target;
            if ((DateTime.UtcNow - peer.LastHit).TotalMilliseconds < WeaponCooldown(peer.Weapon) ||
                !rooms.TryGetValue(peer.Room, out room) || !room.TryGetValue(targetId, out target) ||
                peer.Mode == "survival" || target.Id == peer.Id || target.Health <= 0 || Distance(peer, target) > WeaponRange(peer.Weapon) ||
                (peer.Mode == "teams" && target.Team == peer.Team)) return;

            peer.LastHit = DateTime.UtcNow;
            target.Health = Math.Max(0, target.Health - WeaponDamage(peer.Weapon));
            await Broadcast(peer.Room, new { type = "playerDamaged", targetId = target.Id, health = target.Health, attackerId = peer.Id }, null);
        }
        else if (type == "damage")
        {
            if (peer.Mode != "survival" || (DateTime.UtcNow - peer.LastDamage).TotalMilliseconds < 600 || peer.Health <= 0) return;
            peer.LastDamage = DateTime.UtcNow;
            int amount = (int)Number(data, "amount", 5, 1, 12);
            peer.Health = Math.Max(0, peer.Health - amount);
            await Broadcast(peer.Room, new { type = "playerDamaged", targetId = peer.Id, health = peer.Health, attackerId = "hostile" }, null);
        }
        else if (type == "respawn")
        {
            peer.Health = 100;
            await Broadcast(peer.Room, new { type = "playerRespawned", player = Snapshot(peer) }, null);
        }
        else if (type == "down")
        {
            peer.Health = 0;
            await Broadcast(peer.Room, new { type = "playerDamaged", targetId = peer.Id, health = 0, attackerId = "" }, null);
        }
    }

    private static double Distance(OutlandPeer a, OutlandPeer b)
    {
        double dx = a.X - b.X, dz = a.Z - b.Z;
        return Math.Sqrt(dx * dx + dz * dz);
    }

    private static string NormalizeWeapon(string weapon)
    {
        return weapon == "smg" || weapon == "dmr" || weapon == "shotgun" ? weapon : "rifle";
    }

    private static string NormalizeDropSite(string site)
    {
        return site == "boneyard" || site == "red-mesa" || site == "oasis" || site == "dust-town" || site == "iron-quarry" ? site : "ash-harbor";
    }

    private static string DropSiteName(string site)
    {
        return site == "boneyard" ? "The Boneyard" : site == "red-mesa" ? "Red Mesa" : site == "oasis" ? "Palm Oasis" : site == "dust-town" ? "Dust Town" : site == "iron-quarry" ? "Iron Quarry" : "Ash Harbor";
    }

    private static double DropCenterX(string site)
    {
        return site == "ash-harbor" || site == "oasis" ? -27 : site == "red-mesa" || site == "iron-quarry" ? 27 : 0;
    }

    private static double DropCenterZ(string site)
    {
        return site == "ash-harbor" || site == "boneyard" || site == "red-mesa" ? -21 : 21;
    }

    private static int WeaponDamage(string weapon)
    {
        return weapon == "smg" ? 22 : weapon == "dmr" ? 50 : weapon == "shotgun" ? 70 : 34;
    }

    private static int WeaponCooldown(string weapon)
    {
        return weapon == "smg" ? 85 : weapon == "dmr" ? 360 : weapon == "shotgun" ? 620 : 125;
    }

    private static double WeaponRange(string weapon)
    {
        return weapon == "smg" ? 35 : weapon == "dmr" ? 75 : weapon == "shotgun" ? 20 : 58;
    }

    private static object Snapshot(OutlandPeer peer)
    {
        return new { id = peer.Id, name = peer.Name, x = peer.X, y = peer.Y, z = peer.Z, yaw = peer.Yaw, color = peer.Color, health = peer.Health, team = peer.Team, mode = peer.Mode, dropSite = peer.DropSite, weapon = peer.Weapon };
    }

    private static string Text(Dictionary<string, object> data, string key)
    {
        object value;
        return data.TryGetValue(key, out value) && value != null ? Convert.ToString(value, CultureInfo.InvariantCulture) : "";
    }

    private static double Number(Dictionary<string, object> data, string key, double fallback, double min, double max)
    {
        object value;
        double parsed;
        if (!data.TryGetValue(key, out value) || !Double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) || Double.IsNaN(parsed) || Double.IsInfinity(parsed)) return fallback;
        return Math.Max(min, Math.Min(max, parsed));
    }

    private async Task Send(OutlandPeer peer, object value)
    {
        if (peer.Socket.State != WebSocketState.Open) return;
        byte[] bytes = Encoding.UTF8.GetBytes(serializer.Serialize(value));
        await peer.SendGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (peer.Socket.State == WebSocketState.Open)
                await peer.Socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None).ConfigureAwait(false);
        }
        finally { peer.SendGate.Release(); }
    }

    private async Task Broadcast(string roomName, object value, string exceptId)
    {
        ConcurrentDictionary<string, OutlandPeer> room;
        if (!rooms.TryGetValue(roomName, out room)) return;
        List<Task> sends = new List<Task>();
        foreach (OutlandPeer peer in room.Values)
            if (peer.Id != exceptId) sends.Add(Send(peer, value));
        await Task.WhenAll(sends).ConfigureAwait(false);
    }

    private void RemovePeer(OutlandPeer peer)
    {
        if (String.IsNullOrEmpty(peer.Room)) return;
        ConcurrentDictionary<string, OutlandPeer> room;
        if (rooms.TryGetValue(peer.Room, out room))
        {
            OutlandPeer removed;
            room.TryRemove(peer.Id, out removed);
            Task ignored = Broadcast(peer.Room, new { type = "playerLeft", id = peer.Id }, null);
            if (room.IsEmpty)
            {
                ConcurrentDictionary<string, OutlandPeer> unused;
                rooms.TryRemove(peer.Room, out unused);
            }
        }
        Console.WriteLine(peer.Id + " left room " + peer.Room);
    }
}
'@

Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Web.Extensions', 'System.Net.Http'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$prefix = if ($env:OUTLAND_PREFIX) { $env:OUTLAND_PREFIX } else {
    $port = 3000
    while ($true) {
        $probe = $null
        try {
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $probe.Start()
            break
        }
        catch {
            $port++
        }
        finally {
            if ($null -ne $probe) { $probe.Stop() }
        }
    }
    "http://localhost:$port/"
}
Write-Host "OUTLAND server prefix: $prefix"
if (-not $env:OUTLAND_ALLOWED_ORIGIN) { $env:OUTLAND_ALLOWED_ORIGIN = 'https://delaj382.github.io' }
$roomServer = New-Object OutlandRoomHost($root, $prefix)
$roomServer.RunAsync().GetAwaiter().GetResult()