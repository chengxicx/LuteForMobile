/// YouTube video data parsed from the reading page metadata
/// (the `LUTE_YT_DATA` block rendered by the web player include).
class YoutubeData {
  final String videoId;
  final double startPos;

  const YoutubeData({required this.videoId, this.startPos = 0});
}
