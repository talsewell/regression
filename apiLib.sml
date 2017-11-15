(*
The API that the server and worker agree on.

Reference:

  GET methods:

    waiting:
      returns space-separated list of ids of waiting jobs

    job id:
      returns information on job <id>
      including:
        - commits (including pull request integration, if any)
        - (worker) name and time started (if any)
        - output so far

  POST methods:

    refresh:
      update the queues according to the current state on GitHub
      returns "Refreshed"

    claim id name:
      worker <name> claims job <id>.
      name=<name> is the POST data.
      returns "Claimed"
      fails (409) if <id> is not currently waiting

    append id line:
      record <line> as additional output for job <id> with a timestamp.
      line=<line> is the POST data.
      returns "Appended"
      fails (409) if <id> is not currently running

    log id data:
      append <data> as additional output for job <id>.
      <data> is the POST data.
      returns "Logged"
      fails (409) if <id> is not currently running

    upload id name data:
      save a file called <name> containing <data> as
        an artefact generated by job <id>.
      name=<name>&<data> is the POST data, and <name> must not contain &.
      returns "Uploaded"
      fails (409) if a file called <name> already exists for <id>

    stop id:
      mark job <id> as stopped
      returns "Stopped"
      sends email with output
      fails (409) if <id> is not currently running

    abort id:
      mark job <id> as aborted
      returns "Aborted"
      fails (409) if <id> is not currently stopped

  all failures return text starting with "Error:"

Jobs move (right only) between these states:

  waiting, running, stopped, aborted

waiting = ready to be run, waiting for a worker
running = claimed to be running by a worker
stopped = finished either with success or failure
aborted = the worker did not finish properly

When the waiting queue is refreshed, the commits of running or stopped jobs are
not considered to need running again, whereas the commits of aborted jobs are
(as long as they are still the latest commits).

*)
use "utilLib.sml";

structure apiLib = struct

open utilLib

type id = int
type worker_name = string
type line = string

fun check_id f id =
  0 <= id andalso Int.toString id = f

val host = "https://cakeml.org"
val base_url = "/regression.cgi"
val server = String.concat[host,base_url]
val cakeml_token = until_space (file_to_string "cakeml-token")
                   handle IO.Io _ => (
                     TextIO.output(TextIO.stdErr,"Could not find cakeml-token. Try sha1sum worker.sml >cakeml-token.\n");
                     OS.Process.exit OS.Process.failure)

datatype get_api = Waiting | Job of id
datatype post_api =
    Refresh
  | Claim of id * worker_name
  | Append of id * line (* not including newline *)
  | Log of id * string * int
  | Upload of id * string * int
  | Stop of id
  | Abort of id
datatype api = G of get_api | P of post_api

fun post_response Refresh = "Refreshed\n"
  | post_response (Claim _) = "Claimed\n"
  | post_response (Append _) = "Appended\n"
  | post_response (Stop _) = "Stopped\n"
  | post_response (Abort _) = "Aborted\n"
  | post_response (Log _) = "Logged\n"
  | post_response (Upload _) = "Uploaded\n"

fun percent_decode s =
  let
    fun loop ss acc =
      let
        val (chunk,ss) = Substring.splitl (not o equal #"%") ss
      in
        if Substring.isEmpty ss then
          Substring.concat(List.rev(chunk::acc))
        else
          let
            val (ns,ss) = Substring.splitAt(Substring.triml 1 ss,2)
            val n = #1 (Option.valOf (Int.scan StringCvt.HEX Substring.getc ns))
            val c = Substring.full (String.str (Char.chr n))
          in
            loop ss (c::chunk::acc)
          end
      end
  in
    loop (Substring.full s) []
    handle e => (TextIO.output(TextIO.stdErr,String.concat["percent decode failed on ",s,"\n",exnMessage e,"\n"]); raise e)
  end

fun api_to_string (G Waiting) = "/waiting"
  | api_to_string (P Refresh) = "/refresh"
  | api_to_string (P (Log (id,_,_))) = String.concat["/log/",Int.toString id]
  | api_to_string (P (Upload (id,_,_))) = String.concat["/upload/",Int.toString id]
  | api_to_string (G (Job id)) = String.concat["/job/",Int.toString id]
  | api_to_string (P (Claim (id,_))) = String.concat["/claim/",Int.toString id]
  | api_to_string (P (Append (id,_))) = String.concat["/append/",Int.toString id]
  | api_to_string (P (Stop id)) = String.concat["/stop/",Int.toString id]
  | api_to_string (P (Abort id)) = String.concat["/abort/",Int.toString id]

fun post_curl_args (Append (_,line)) = ["--data-urlencode",String.concat["line=",line]]
  | post_curl_args (Claim  (_,name)) = ["--data-urlencode",String.concat["name=",name]]
  | post_curl_args (Log    (_,file,_)) = ["--data-binary",String.concat["@",file]]
  | post_curl_args (Upload (_,file,_)) = ["--data",String.concat["name=",List.last(#arcs(OS.Path.fromString file))],"--data-binary",String.concat["@",file]]
  | post_curl_args (Stop  _) = ["--data",""]
  | post_curl_args (Abort _) = ["--data",""]
  | post_curl_args (Refresh) = ["--data",""]

fun api_curl_args (G _) = []
  | api_curl_args (P p) = post_curl_args p

fun id_from_string n =
  case Int.fromString n of NONE => NONE
  | SOME id => if check_id n id then SOME id else NONE

fun read_query prefix len =
  case String.tokens (equal #"&") (TextIO.inputN(TextIO.stdIn,len))
  of [s] =>
    if String.isPrefix (String.concat[prefix,"="]) s then
      SOME (percent_decode (String.extract(s,String.size prefix + 1,NONE)))
    else NONE
  | _ => NONE

fun get_from_string s =
  if s = "/waiting" then SOME Waiting else
  case String.tokens (equal #"/") s of
    ["job",n] => Option.map Job (id_from_string n)
  | _ => NONE

fun read_name l =
  let
    fun assert b = if b then () else raise Option
    val prefix = "name="
    val () = assert (String.size prefix <= l)
    val () = assert (TextIO.inputN(TextIO.stdIn,String.size prefix) = prefix)
    fun loop (acc,l) =
      let
        val c = Option.valOf (TextIO.input1 TextIO.stdIn)
      in
        if c = #"&"
        then (String.implode(List.rev acc),l-1)
        else loop (c::acc,l-1)
      end
  in SOME (loop ([],l)) end
  handle Option => NONE

fun post_from_string s len =
  if s = "/refresh" then SOME Refresh
  else (case String.tokens (equal #"/") s of
    ["claim",n] => Option.mapPartial
                    (fn id => Option.map (fn s => Claim(id,s))
                              (Option.mapPartial (read_query "name") len))
                    (id_from_string n)
  | ["append",n] => Option.mapPartial
                    (fn id => Option.map (fn s => Append(id,s))
                              (Option.mapPartial (read_query "line") len))
                    (id_from_string n)
  | ["log",n] => Option.mapPartial
                    (fn id => Option.map (fn l => Log(id,"",l)) len)
                    (id_from_string n)
  | ["upload",n] => Option.mapPartial
                    (fn id => Option.map (fn (name,l) => Upload(id,name,l))
                                         (Option.mapPartial read_name len))
                    (id_from_string n)
  | ["stop",n] => Option.map Stop (id_from_string n)
  | ["abort",n] => Option.map Abort (id_from_string n)
  | _ => NONE)

type bare_pr = { head_sha : string, base_sha : string }
datatype bare_integration = Bbr of string | Bpr of bare_pr
type bare_snapshot = { bcml : bare_integration, bhol : string }

fun read_bare_snapshot inp =
  let
    fun read_line () = Option.valOf (TextIO.inputLine inp)

    val head_sha = extract_prefix_trimr "CakeML: " (read_line())
    val _ = read_line ()
    val line = read_line ()
    val (line,base_sha) =
      if String.isPrefix "#" line then
        let
          val line = read_line ()
          val _ = read_line ()
        in (read_line(), SOME (extract_prefix_trimr "Merging into: " line)) end
      else (line, NONE)
    val hol_sha = extract_prefix_trimr "HOL: " line
  in
    { bcml = case base_sha
               of NONE => Bbr head_sha
                | SOME base_sha => Bpr { head_sha = head_sha, base_sha = base_sha }
    , bhol = hol_sha }
  end

fun read_job_type inp =
  let
    fun read_line () = Option.valOf (TextIO.inputLine inp)
    val _ = read_line () (* CakeML *)
    val _ = read_line () (* msg *)
    val line = read_line ()
  in
    if String.isPrefix "#" line then
      Substring.string(#1(extract_word line))
    else "master"
  end

datatype status = Pending | Success | Failure | Aborted

fun read_status inp =
  let
    fun loop () =
      case TextIO.inputLine inp of NONE => Aborted
      | SOME line =>
        if String.isSubstring "FAILED" line
          then Failure
        else if String.isSubstring "SUCCESS" line
          then Success
        else loop ()
  in loop () end

end
