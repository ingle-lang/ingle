// std/fs — filesystem helpers beyond the read_file / write_file / list_dir builtins. Currently
// mkdir (for laying out a repo/config directory, e.g. Quog's .quog/); the broader path + stat set
// (exists / rename / dirname / join / …) is OFI-190. Thin FFI, DEFAULT build, no dependency.
extern "c" {
    fn em_mkdir(path: string) -> i64
}


// mkdir creates directory `path` (mode 0777, umask-masked). Returns 0 on success, or -1 if it could
// not be created — most commonly because it already exists, which a caller that just wants the
// directory present can safely ignore.
fn mkdir(path: string) -> int {
    return em_mkdir(path)
}
