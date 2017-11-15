(*
  Worker that claims and runs regression test jobs.

  Assumes the following are available:
    /usr/bin/curl, /usr/bin/git, /usr/bin/time, poly

  Also assumes the default shell (/bin/sh) understands
    [var=val] cmd [args ...] >file 2>&1
  to mean redirect both stdout and stderr to file when running
  cmd on args in an environment augmented with var set to val (if present),
  and >>file instead of >file appends to file instead of truncating it.

  Can be run either as a daemon (default) that will keep looking for work by
  polling or as a one-shot command (--no-poll) that will do nothing if no work
  is currently available. This means polling or work notifications can be
  handled externally if desired.

*)

use "apiLib.sml"; open apiLib

fun usage_string name = String.concat[
  name, " [options]\n\n",
  "Runs waiting jobs from ",server,"/\n\n",
  "Summary of options:\n",
  "  --no-poll   : Exit when no waiting jobs are found rather than polling.\n",
  "                Will still check for more waiting jobs after completing a job.\n",
  "  --no-loop   : Exit after finishing a job, do not check for more waiting jobs.\n",
  "  --select id : Ignore the waiting jobs list and instead attempt to claim job <id>.\n",
  "  --resume id : Assume job <id> has previously been claimed by this worker and\n",
  "                attempt to start running it again. If the job fails again,\n",
  "                exit (even without --no-loop).\n",
  "  --upload id : Assume this worker has just finished job <id> and upload its build\n",
  "                artefacts (usually automatic after master succeeds), then exit.\n",
  "  --abort id  : Mark job <id> as having aborted, i.e., stopped without a proper\n",
  "                success or failure, then exit.\n",
  "  --refresh   : Refresh the server's waiting queue from GitHub then exit.\n"];

(*

  All work will be carried out in the current directory
  (or subdirectories of it) with no special permissions.
  Assumes this directory starts empty except for the
  worker executable and one file
    name
  containing this worker node's identity. This could be
  created as follows:
    uname -norm > name
  It must not start with whitespace nor contain any single quotes.

  Manipulates working directories for HOL and CakeML, which are created if
  necessary. If a job can reuse the HOL working directory without rebuilding
  (the commit has not changed), then it will be reused. Otherwise, it is
  cleaned ("git clean -xdf") and rebuilt. The CakeML working directory is
  cleaned before every job.

  Jobs are handled as follows:
    1. Find a job in the waiting queue
    2. Claim the job
    3. Set up HOL and CakeML working directories
       according to the job snapshot
    4. Build HOL, capturing stdout and stderr
       On failure:
         1. Append "FAILED: building HOL"
         2. Log the captured output
         3. Stop the job
    5. For each directory in the CakeML build sequence
       1. Append "Starting <dir>"
       2. Holmake in that directory,
            capturing stdout and stderr,
            and capturing time and memory usage
          On failure:
            1. Append "FAILED: <dir>"
            2. Log the captured output
            3. Stop the job
       3. Append "Finished <dir>: <time> <memory>"
    6. Append "SUCCESS"
    7. Stop the job
*)

fun warn ls = (
  TextIO.output(TextIO.stdErr,String.concat ls);
  TextIO.output(TextIO.stdErr,"\n"))

fun die ls = (
  warn ls;
  OS.Process.exit OS.Process.failure;
  raise (Fail "impossible"))

fun diag ls = (
  TextIO.output(TextIO.stdOut,String.concat ls);
  TextIO.output(TextIO.stdOut,"\n"))

fun assert b ls = if b then () else die ls

fun file_to_line f =
  let
    val inp = TextIO.openIn f
    val lopt = TextIO.inputLine inp
    val () = TextIO.closeIn inp
  in
    case lopt of NONE => ""
    | SOME line => String.extract(line,0,SOME(String.size line - 1))
  end

val system_output = system_output die

val capture_file = "regression.log"
val timing_file = "timing.log"

fun system_capture_with redirector cmd_args =
  let
    (* This could be implemented using Posix without relying on the shell *)
    val status = OS.Process.system(String.concat[cmd_args, redirector, capture_file, " 2>&1"])
  in OS.Process.isSuccess status end

val system_capture = system_capture_with " >"
val system_capture_append = system_capture_with " >>"

val poll_delay = Time.fromSeconds(60 * 30)

structure API = struct
  val endpoint = String.concat[server,"/api"]
  val std_options = ["--silent","--show-error","--header",String.concat["Authorization: Bearer ",cakeml_token]]
  fun curl_cmd api = (curl_path,
      std_options
    @ api_curl_args api
    @ [String.concat[endpoint,api_to_string api]])
  val raw_post = system_output o curl_cmd o P
  val get = system_output o curl_cmd o G
  fun post p =
    let
      val expected = post_response p
      val response = raw_post p
    in
      assert (response=expected)
        ["Unexpected response:\nWanted: ",expected,"Got: ",response]
    end
end

val HOLDIR = "HOL"
val hol_remote = "https://github.com/HOL-Theorem-Prover/HOL.git"
val CAKEMLDIR = "cakeml"
val cakeml_remote = "https://github.com/CakeML/cakeml.git"

val artefact_paths = [
  "compiler/bootstrap/compilation/x64/cake-x64.tar.gz",
  "compiler/bootstrap/compilation/riscv/cake-riscv.tar.gz" ]

val git_path = "/usr/bin/git"
val git_clean = (git_path,["clean","-d","--force","-x"])
fun git_reset sha = (git_path,["reset","--hard","--quiet",sha])
val git_fetch = (git_path,["fetch","origin"])
fun git_sha_of head = (git_path,["rev-parse","--verify",head])
val git_head = git_sha_of "HEAD"
val git_merge_head = git_sha_of "MERGE_HEAD"

local
  open OS.FileSys
in
  fun ensure_clone_exists remote options dir =
    if access (dir,[]) then
      if isDir dir then
        let
          val () = chDir dir
          val output = system_output (git_path,["remote","get-url","origin"])
          val () = chDir OS.Path.parentArc
        in
          assert (String.isPrefix remote output) [dir," remote misconfigured"]
        end
      else die [dir," is not a directory"]
    else
      let
        val () = diag [dir," does not exist: will clone"]
        val status = OS.Process.system (String.concat[git_path," clone ",options,remote," ",dir])
      in
        assert (OS.Process.isSuccess status) ["git clone failed for ",dir]
      end
end

fun ensure_hol_exists () = ensure_clone_exists hol_remote "--single-branch " HOLDIR
fun ensure_cakeml_exists () = ensure_clone_exists cakeml_remote "" CAKEMLDIR

fun link_poly_includes () =
  let
    val includes_file = "poly-includes.ML"
    val f = OS.Path.concat(OS.Path.parentArc,includes_file)
  in
    if OS.FileSys.access(f,[OS.FileSys.A_READ]) then
      Posix.FileSys.symlink { old = OS.Path.concat(OS.Path.parentArc,f),
                              new = OS.Path.concat("tools-poly",includes_file) }
      before diag ["Linking to custom ",includes_file]
    else ()
  end

fun prepare_hol sha =
  let
    val () = ensure_hol_exists ()
    val () = OS.FileSys.chDir HOLDIR
    val () = ignore (system_output git_fetch)
    val output = system_output git_head
    val reuse = String.isPrefix sha output andalso
                OS.FileSys.access("bin/build",[OS.FileSys.A_EXEC])
    val () =
      if reuse
      then diag ["Reusing HOL working directory built at same commit"]
      else (system_output (git_reset sha);
            system_output git_clean;
            link_poly_includes ())
    val () = OS.FileSys.chDir OS.Path.parentArc
  in
    reuse
  end

fun prepare_cakeml x =
  let
    val () = ensure_cakeml_exists ()
    val () = OS.FileSys.chDir CAKEMLDIR
    val _ = system_output git_fetch
    val _ =
      case x of
        Bbr sha => system_output (git_reset sha)
      | Bpr {head_sha, base_sha} =>
          (system_output (git_reset base_sha);
           system_output (git_path,["merge","--no-commit","--quiet",head_sha]))
    val _ = system_output git_clean
  in
    OS.FileSys.chDir OS.Path.parentArc
  end

local
  val configure_hol = "poly --script tools/smart-configure.sml"
in
  fun build_hol reused id =
    let
      val () = OS.FileSys.chDir HOLDIR
      val configured =
        reused orelse system_capture configure_hol
      val built = configured andalso
                  system_capture_append "bin/build --nograph"
      val () = OS.FileSys.chDir OS.Path.parentArc
      val () = if built then () else
               (API.post (Append (id, "FAILED: building HOL"));
                API.post (Log(id,capture_file,0));
                API.post (Stop id))
    in
      built
    end
end

fun upload id f =
  let
    val p = OS.Path.concat(CAKEMLDIR,f)
  in
    if OS.FileSys.access(p,[])
    then API.post (Upload(id,p,0))
    else warn ["Could not find ",p," to upload."]
  end

local
  val resume_file = "resume"
  val time_options = String.concat["--format='%e %M' --output='",timing_file,"'"]
  val max_dir_length = 50
  fun pad dir =
    let
      val z = String.size dir
      val n = if z < max_dir_length then max_dir_length - z
              else (warn ["max_dir_length is too small for ",dir]; 1)
    in CharVector.tabulate(n,(fn _ => #" ")) end
  val no_skip = ((fn _ => false), "Starting ")
in
  fun run_regression resumed is_master id =
    let
      val root = OS.FileSys.getDir()
      val holdir = OS.Path.concat(root,HOLDIR)
      val holmake_cmd =
        String.concat["HOLDIR='",holdir,"' /usr/bin/time ",time_options,
                      " '",holdir,"/bin/Holmake' --qof"]
      val cakemldir = OS.Path.concat(root,CAKEMLDIR)
      val () = OS.FileSys.chDir CAKEMLDIR
               handle e as OS.SysErr _ => die ["Failed to enter ",CAKEMLDIR,
                                               "\n","root: ",root,
                                               "\n",exnMessage e]
      val () = assert (OS.FileSys.getDir() = cakemldir) ["impossible failure"]
      val seq = TextIO.openIn("developers/build-sequence")
                handle e as OS.SysErr _ => die ["Failed to open build-sequence: ",exnMessage e]
      val skip =
        (if resumed then (not o equal (file_to_string resume_file), "Resuming ")
                    else no_skip)
        handle (e as IO.Io _) => die["Failed to load resume file: ",exnMessage e]
      fun loop skip =
        case TextIO.inputLine seq of NONE => true
        | SOME line =>
          if String.isPrefix "#" line orelse
             String.isPrefix "\n" line orelse
             #1 skip line
          then loop skip else
          let
            val () = output_to_file (resume_file, line)
            val dir = until_space line
            val () = API.post (Append(id, String.concat[#2 skip,dir]))
            val entered = (OS.FileSys.chDir dir; true)
                          handle e as OS.SysErr _ => (API.post (Append(id, exnMessage e)); false)
          in
            if entered andalso system_capture holmake_cmd then
              (API.post (Append(id,
                 String.concat["Finished ",dir,pad dir,file_to_line timing_file]));
               OS.FileSys.chDir cakemldir;
               loop no_skip)
            else
              (API.post (Append(id,String.concat["FAILED: ",dir]));
               API.post (Log(id,capture_file,0));
               API.post (Stop id);
               false)
          end
      val success = loop skip
      val () =
        if success then
          let in
            API.post (Append(id,"SUCCESS"));
            if is_master then List.app (upload id) artefact_paths else ();
            API.post (Stop id)
          end
        else ()
      val () = OS.FileSys.chDir root
    in
      success
    end
end

fun validate_resume jid bhol bcml =
  let
    val () = diag ["Checking HOL for resuming job ",jid]
    val () = OS.FileSys.chDir HOLDIR
    val head = system_output git_head
    val () = assert (String.isPrefix bhol head) ["Wrong HOL commit: wanted ",bhol,", at ",head]
    val () = OS.FileSys.chDir OS.Path.parentArc
    val () = diag ["Checking CakeML for resuming job ",jid]
    val () = OS.FileSys.chDir CAKEMLDIR
    val () =
      case bcml of
        Bbr sha => assert (String.isPrefix sha (system_output git_head)) ["Wrong CakeML commit: wanted ",sha]
      | Bpr {head_sha, base_sha} =>
        (assert (String.isPrefix base_sha (system_output git_head)) ["Wrong CakeML base commit: wanted ",base_sha];
         assert (String.isPrefix head_sha (system_output git_merge_head)) ["Wrong CakeML head commit: wanted ",head_sha])
    val () = OS.FileSys.chDir OS.Path.parentArc
  in
    true
  end

fun work resumed id =
  let
    val response = API.get (Job id)
    val jid = Int.toString id
  in
    if String.isPrefix "Error:" response
    then (warn [response]; false) else
    let
      val inp = TextIO.openString response
      val {bcml,bhol} = read_bare_snapshot inp
                        handle Option => die["Job ",jid," returned invalid response"]
      val () = TextIO.closeIn inp
      val built_hol =
        if resumed then validate_resume jid bhol bcml
        else let
          val () = diag ["Preparing HOL for job ",jid]
          val reused = prepare_hol bhol
          val () = diag ["Preparing CakeML for job ",jid]
          val () = prepare_cakeml bcml
          val () = diag ["Building HOL for job ",jid]
          val () = API.post (Append(id,"Building HOL"))
        in
          build_hol reused id
        end
      val is_master = case bcml of Bbr _ => true | _ => false
    in
      built_hol andalso
      (diag ["Running regression for job ",jid];
       run_regression resumed is_master id)
    end
  end

fun get_int_arg name [] = NONE
  | get_int_arg name [_] = NONE
  | get_int_arg name (x::y::xs) =
    if x = name then Int.fromString y
    else get_int_arg name (y::xs)

fun main () =
  let
    val args = CommandLine.arguments()
    val () = if List.exists (fn a => a="--help" orelse a="-h" orelse a="-?") args
             then (TextIO.output(TextIO.stdOut, usage_string(CommandLine.name())); OS.Process.exit OS.Process.success)
             else ()
    val () = if List.exists (equal "--refresh") args
             then (TextIO.output(TextIO.stdOut, API.raw_post Refresh); OS.Process.exit OS.Process.success)
             else ()
    val () = case get_int_arg "--abort" args of NONE => ()
             | SOME id => (
                 diag ["Marking job ",Int.toString id," as aborted."];
                 API.post (Abort id); OS.Process.exit OS.Process.success)
    val () = case get_int_arg "--upload" args of NONE => ()
             | SOME id => let in
                 diag ["Uploading artefacts for job ",Int.toString id,"."];
                 List.app (upload id) artefact_paths;
                 OS.Process.exit OS.Process.success
               end
    val no_poll = List.exists (equal"--no-poll") args
    val no_loop = List.exists (equal"--no-loop") args
    val resume = get_int_arg "--resume" args
    val select = get_int_arg "--select" args
    val name = file_to_line "name"
               handle IO.Io _ => die["Could not determine worker name. Try uname -norm >name."]
    fun loop resume =
      let
        val waiting_ids =
          case select of SOME id => [id] | NONE =>
          case resume of SOME id => [id] | NONE =>
          List.map (Option.valOf o Int.fromString)
            (String.tokens Char.isSpace (API.get Waiting))
      in
        case waiting_ids of [] =>
          if no_poll then diag ["No waiting jobs. Exiting."]
          else (diag ["No waiting jobs. Will check again later."]; OS.Process.sleep poll_delay; loop NONE)
        | (id::_) => (* could prioritise for ids that match our HOL dir *)
          let
            val jid = Int.toString id
            val () = diag ["About to work on ",server,"/job/",jid]
            val resumed = Option.isSome resume
            val claim = Claim(id,name)
            val claim_response = post_response claim
            val response = if resumed then claim_response
                           else API.raw_post claim
            val success =
              if response=claim_response
              then work resumed id
              else (warn ["Claim of job ",jid," failed: ",response]; false)
          in
            if no_loop orelse (resumed andalso not success)
            then diag ["Finished work. Exiting."]
            else (diag ["Finished work. Looking for more."]; loop NONE)
          end
      end handle e => die ["Unexpected failure: ",exnMessage e]
  in loop resume end
