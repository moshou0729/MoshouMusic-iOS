// 咪咕音乐源脚本
//   搜索:   https://m.music.migu.cn/migu/remoting/scr_search_tag (JSON)
//   播放:   优先使用搜索结果内的直链 (mp3 / newRateFormats), 否则兜底返回空
//   推荐:   热门关键词搜索兜底
;(function() {
    const source = 'mg'

    lx.send(EVENT_NAMES.inited, {
        sources: ['mg'],
        qualities: ['128k', '320k', 'flac']
    })

    lx.on(EVENT_NAMES.request, function(data, callback) {
        const { source: src, action, info } = data
        if (src !== source) return

        switch (action) {
            case 'musicSearch': handleSearch(info, callback); break
            case 'musicUrl':    handleMusicUrl(info, callback); break
            case 'lyric':       handleLyric(info, callback); break
            case 'pic':         handlePic(info, callback); break
            case 'musicBoard':  handleBoard(info, callback); break
            default: callback({ message: '未知操作: ' + action }, null)
        }
    })

    const HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15',
        'Referer': 'https://m.music.migu.cn/'
    }

    const HOT = ['孤勇者', '晴天', '起风了', '海阔天空', '稻香', '光年之外', '演员', '夜曲']

    function cleanText(s) {
        return (s || '').replace(/&nbsp;/g, ' ').replace(/<[^>]+>/g, '').trim()
    }

    function parseBody(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) {}
        return null
    }

    function durationToSec(d) {
        if (typeof d === 'number') return d
        if (!d) return 0
        const parts = String(d).split(':')
        if (parts.length === 3) return (+parts[0]) * 3600 + (+parts[1]) * 60 + (+parts[2])
        if (parts.length === 2) return (+parts[0]) * 60 + (+parts[1])
        return parseInt(d, 10) || 0
    }

    function extractUrl(item) {
        if (item.mp3) return item.mp3
        const formats = item.newRateFormats || item.rateFormats || []
        for (let i = 0; i < formats.length; i++) {
            if (formats[i].url) return formats[i].url
            if (formats[i].downUrl) return formats[i].downUrl
        }
        return ''
    }

    function mapItem(item) {
        const cover = (item.cover || '').replace('{size}', '150')
        return {
            songmid: String(item.songId || ''),
            name: cleanText(item.songName) || '未知歌曲',
            singer: cleanText(item.singerName) || '未知歌手',
            albumName: cleanText(item.albumName),
            albumId: String(item.albumId || ''),
            img: cover,
            interval: durationToSec(item.duration),
            quality: '320k',
            meta: { playUrl: extractUrl(item) }
        }
    }

    function parseMusics(result) {
        if (!result) return []
        if (result.musics) return result.musics
        if (result.result && result.result.musics) return result.result.musics
        if (result.resultData && result.resultData.musics) return result.resultData.musics
        return []
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1
        const url = 'https://m.music.migu.cn/migu/remoting/scr_search_tag?rows=30&type=2' +
            '&keyword=' + encodeURIComponent(keyword) + '&pgc=' + page + '&filterDup=true'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            const result = parseBody(resp.body)
            const musics = parseMusics(result)
            if (!musics.length) {
                callback({ message: '搜索接口返回异常 (HTTP ' + resp.statusCode + ')' }, null)
                return
            }
            const list = musics.map(mapItem).filter(function(item) { return item.songmid && item.name })
            callback(null, { list: list, total: list.length })
        })
    }

    // ==================== 播放链接 ====================
    function handleMusicUrl(info, callback) {
        // 搜索时已附带直链 (meta.playUrl)
        const playUrl = info.meta && info.meta.playUrl
        if (playUrl) {
            callback(null, { url: playUrl })
            return
        }
        // 否则尝试详情接口换取直链
        const songId = info.songmid
        const url = 'https://music.migu.cn/v3/api/music/audioPlayer/getPlayInfo?songId=' + songId
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                const play = result.data && result.data.url
                if (play) callback(null, { url: play })
                else callback({ message: '咪咕未返回播放直链(可能需鉴权)' }, null)
            } catch (e) {
                callback({ message: '咪咕播放接口返回非 JSON' }, null)
            }
        })
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        // 咪咕歌词需登录态, 这里兜底返回空
        callback(null, { lyric: '', tlyric: '' })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        // 搜索时已带封面, pic 动作传入 songmid 时无法回溯, 直接返回空让上层用搜索封面
        callback(null, { url: '' })
    }

    // ==================== 推荐 (热门关键词搜索兜底) ====================
    function handleBoard(info, callback) {
        const picks = [HOT[0], HOT[2], HOT[4]]
        let merged = []
        let done = 0
        picks.forEach(function(kw) {
            handleSearch({ keyword: kw, page: 1 }, function(err, data) {
                done++
                if (!err && data && data.list) merged = merged.concat(data.list)
                if (done === picks.length) {
                    const seen = {}
                    const out = []
                    merged.forEach(function(s) {
                        if (!seen[s.songmid]) { seen[s.songmid] = 1; out.push(s) }
                    })
                    callback(null, { list: out.slice(0, 30), total: out.length })
                }
            })
        })
    }
})()
