#!/usr/bin/env python3
"""Exercise the production Swift MP4 timing repair on macOS (no simulator needed)."""
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ios/cookoo_video_export/Sources/cookoo_video_export/AudioMux.swift'


def box(kind, payload):
    return struct.pack('>I4s', len(payload) + 8, kind.encode()) + payload


def movie(scale, entries, duration=None):
    duration = sum(n * delta for n, delta in entries) if duration is None else duration
    mdhd = box('mdhd', struct.pack('>6I', 0, 0, 0, scale, duration, 0))
    hdlr = box('hdlr', struct.pack('>2I4s', 0, 0, b'vide'))
    stts = box('stts', struct.pack('>2I', 0, len(entries)) + b''.join(
        struct.pack('>2I', n, delta) for n, delta in entries))
    index = box('moov', box('trak', box('mdia', mdhd + hdlr + box('minf', box('stbl', stts)))))
    return box('mdat', b'compressed payload and chunk positions stay unchanged') + index


class VideoTimingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.temp.name)
        # Compile the actual production repair and its parser, excluding Flutter/AVFoundation.
        swift = cls.folder / 'main.swift'
        swift.write_text('import Foundation\n' + 'func preserveVideoTiming' + SOURCE.read_text().split('func preserveVideoTiming', 1)[1] + '\ntry preserveVideoTiming(from: URL(fileURLWithPath: CommandLine.arguments[1]), to: URL(fileURLWithPath: CommandLine.arguments[2]))\n')
        cls.runner = cls.folder / 'repair'
        subprocess.run(['xcrun', 'swiftc', str(swift), '-o', str(cls.runner)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def repair(self, source, copied, expected):
        original = self.folder / 'source.mp4'
        output = self.folder / 'output.mp4'
        original.write_bytes(source)
        output.write_bytes(copied)
        subprocess.run([str(self.runner), str(original), str(output)], check=True)
        self.assertEqual(output.read_bytes(), expected)
        self.assertEqual(original.read_bytes(), source)

    def test_integer_rate_rescaled_to_600(self):
        self.repair(movie(30, [(593, 1)]), movie(600, [(592, 20), (1, 40)]),
                    movie(600, [(592, 20), (1, 20)]))

    def test_fractional_rate_unchanged_timebase(self):
        self.repair(movie(30000, [(61, 1001)]), movie(30000, [(60, 1001), (1, 2002)]),
                    movie(30000, [(60, 1001), (1, 1001)]))

    def test_integer_rate_unchanged_timebase(self):
        self.repair(movie(30, [(593, 1)]), movie(30, [(592, 1), (1, 2)]),
                    movie(30, [(592, 1), (1, 1)]))

    def test_already_correct_is_untouched(self):
        copied = movie(600, [(593, 20)])
        self.repair(movie(30, [(593, 1)]), copied, copied)

    def test_variable_frame_rate_is_untouched(self):
        copied = movie(600, [(592, 20), (1, 40)])
        self.repair(movie(30, [(592, 1), (1, 2)]), copied, copied)

    def test_missing_frame_is_untouched(self):
        copied = movie(600, [(591, 20), (1, 40)])
        self.repair(movie(30, [(593, 1)]), copied, copied)

    def test_inexact_timebase_is_untouched(self):
        copied = movie(100, [(592, 3), (1, 6)])
        self.repair(movie(30, [(593, 1)]), copied, copied)

    def test_other_timing_change_is_untouched(self):
        copied = movie(600, [(591, 20), (1, 21), (1, 40)])
        self.repair(movie(30, [(593, 1)]), copied, copied)


if __name__ == '__main__':
    unittest.main()
