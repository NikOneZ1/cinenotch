#pragma once

/// Runs the Now Playing bridge until stdin closes. Called by /usr/bin/perl as an XSUB, hence
/// the (interpreter, CV) arguments, which it ignores. See NowPlaying.swift in CineNotch.
void cinenotch_now_playing_main(void *perl, void *cv);
