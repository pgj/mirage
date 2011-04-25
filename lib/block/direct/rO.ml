(*
 * Copyright (c) 2011 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

(* A simple read-only block filesystem *)
open Lwt
open Printf

type file = {
  name: string;
  offset: int64;
  len: int64;
}

type t = {
  vbd: OS.Blkif.t;
  files: (string, file) Hashtbl.t;
}

let create vbd =
  let files = Hashtbl.create 7 in
  let rec read_page off =
    lwt v = OS.Blkif.read_page vbd off in
    let rec parse_page num =
      let loff = num * 512 in
      match OS.Istring.to_uint32_be v loff with
      |0xDEADBEEFl -> begin
        let offset = OS.Istring.to_uint64_be v (loff+4) in
        let len = OS.Istring.to_uint64_be v (loff+12) in
        let namelen = OS.Istring.to_uint32_be v (loff+20) in
        let name = OS.Istring.to_string v (loff+24) (Int32.to_int namelen) in
        if Int64.rem offset 512L <> 0L then
          fail (Failure (sprintf "unaligned offset file found: offset=%Lu" offset))
        else begin
          Hashtbl.add files name { name; offset; len };
          printf "Read file: %s %Lu[%Lu]\n%!" name offset len;
          if num = 7 then
            read_page (Int64.add off 8L)
          else
            parse_page (num+1)
        end
      end
      |_ -> return ()
    in
    parse_page 0 in
  read_page 0L >>
  return { vbd; files }

exception Error of string

(* Read directly from the disk, no caching *)
let read t filename =
  try
    let file = Hashtbl.find t.files filename in
    let offset = Int64.div file.offset 512L in
    assert(Int64.rem file.offset 512L = 0L);
    let cur_seg = ref None in
    let pos = ref 0L in
    let rec readfn () =
      (* Check if we have an active segment *)
      match !cur_seg with
      |Some (idx, arr) ->
        (* Traversing an existing segment, so get next in element *)
        let r =
          (* If this is the end of the file, might need to be a partial view *)
          if Int64.add !pos 512L >= file.len then begin
            let sz = Int64.sub file.len !pos in
            pos := Int64.add !pos sz;
            cur_seg := None;
            OS.Istring.sub arr.(idx) 0 (Int64.to_int sz)
          end else begin
            pos := Int64.add !pos 512L;
            cur_seg := if idx < Array.length arr - 1 then Some (idx+1, arr) else None;
            arr.(idx)
          end
        in
        return (Some r)
      |None ->
        if !pos >= file.len then begin
          return None (* EOF *)
        end else begin
          (* Need to retrieve more data *)
          (* Assuming a sector size of 512, we can read a maximum of 
             11 * 8 512-byte sectors (44KB=45056b) per scatter-gather request *)
          let need_bytes = min 45056L (Int64.sub file.len !pos) in
          (* Get rounded up number of sectors *)
          let need_sectors = Int64.(div (add need_bytes 511L) 512L) in
          lwt arr = OS.Blkif.read_512 t.vbd (Int64.add offset !pos) need_sectors in
          cur_seg := Some (0, arr);
          readfn ()
        end
    in
    return (Lwt_stream.from readfn)
  with
  | Not_found -> fail (Error "file not found")
