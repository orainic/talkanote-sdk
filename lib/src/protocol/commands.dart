/// Command codes of the talkaNote card's BLE protocol.
///
/// Every frame's DATA starts with a TYPE byte and a CMD byte. See
/// `docs/protocol.md` for parameters and replies.
library;

/// DATA types.
abstract final class FrameType {
  static const control = 0;
  static const live = 1;
  static const file = 2;

  /// Recording control and button events. A frame of this type with no CMD
  /// byte is an ACK.
  static const recording = 3;
}

/// TYPE 0: control.
abstract final class ControlCmd {
  static const syncTime = 0;
  static const getStorage = 1;
  static const storage = 2;
  static const getBattery = 3;
  static const battery = 4;
  static const getVersion = 10;
  static const version = 11;
  static const appState = 18;
}

/// TYPE 1: live audio.
abstract final class LiveCmd {
  /// App to card: start streaming. Card to app: file name of the recording.
  static const start = 0;
  static const audio = 1;
  static const stop = 2;
  static const pauseResume = 3;
  static const state = 4;
}

/// TYPE 2: files.
abstract final class FileCmd {
  static const list = 0;
  static const listBatch = 1;
  static const download = 2;
  static const downloadStart = 3;
  static const downloadData = 4;
  static const downloadEnd = 5;
  static const abort = 7;
  static const deleteOne = 8;
  static const deleteAll = 9;
  static const deleteAllResult = 10;
  static const abortResult = 11;
  static const downloadRange = 12;
  static const deleteOneResult = 13;
  static const listDone = 18;
}

/// TYPE 3: recording control. The card also sends [start], [save], [pause]
/// and [resume] on its own when its button is pressed; the app must answer
/// with `cmd + 1`.
abstract final class RecordCmd {
  static const start = 1;
  static const startResult = 2;
  static const save = 3;
  static const saveResult = 4;
  static const pause = 5;
  static const pauseResult = 6;
  static const resume = 7;
  static const resumeResult = 8;
  static const getState = 19;
  static const state = 20;
  static const getTime = 21;
  static const time = 22;
  static const getFileName = 23;
  static const fileName = 24;
  static const getGain = 25;
  static const gain = 26;
  static const setGain = 27;
  static const setGainResult = 28;

  static const buttonRequests = {start, save, pause, resume};
}

/// Result codes of [FileCmd.downloadEnd].
abstract final class DownloadEndCode {
  static const ok = 0;
  static const notFound = 1;
  static const offsetTooLarge = 2;
  static const stopped = 3;
}
