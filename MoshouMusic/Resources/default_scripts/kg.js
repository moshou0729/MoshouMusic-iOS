// 酷狗音乐源脚本
//   搜索:   https://songsearch.kugou.com/song_search_v2 (JSON, 无需鉴权)
//   播放:   https://www.kugou.com/yy/index.php?r=play/getdata&hash= (返回 play_url, 真机通常可用)
//   歌词:   https://www.kugou.com/yy/index.php?r=play/getdata 内含 lyrics 字段
//   推荐:   酷狗官方榜单接口变动较大, 这里用热门关键词搜索兜底, 保证有真实内容
;(function() {
    const source = 'kg'

    lx.send(EVENT_NAMES.inited, {
        sources: ['kg'],
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
        'Referer': 'https://www.kugou.com/'
    }

    const HOT = ['孤勇者', '晴天', '起风了', '海阔天空', '稻香', '光年之外', '演员', '夜曲']

    function cleanText(s) {
        return (s || '').replace(/<em>|<\/em>|&nbsp;/g, '').replace(/&#\d+;/g, '').trim()
    }

    function parseBody(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) {}
        return null
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1
        const url = 'https://songsearch.kugou.com/song_search_v2?keyword=' +
            encodeURIComponent(keyword) +
            '&page=' + page + '&pagesize=30&userid=-1&clientver=&platform=WebFilter' +
            '&tag=em&filter=2&iscorrection=1&privilege_filter=0'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            const result = parseBody(resp.body)
            if (!result || !result.data || !result.data.lists) {
                callback({ message: '搜索接口返回异常 (HTTP ' + resp.statusCode + ')' }, null)
                return
            }
            const list = result.data.lists.map(function(item) {
                const hash = item.FileHash || ''
                return {
                    songmid: hash,
                    name: cleanText(item.SongName) || '未知歌曲',
                    singer: cleanText(item.SingerName) || '未知歌手',
                    albumName: cleanText(item.AlbumName),
                    albumId: String(item.AlbumID || ''),
                    img: (item.AlbumPic || '').replace('{size}', '150'),
                    interval: parseInt(item.Duration || '0', 10) || 0,
                    quality: '320k'
                }
            }).filter(function(item) { return item.songmid && item.name })
            callback(null, { list: list, total: list.length })
        })
    }

    // ==================== 播放链接 ====================
    function requestUrl(hash, callback) {
        const url = 'https://www.kugou.com/yy/index.php?r=play/getdata&hash=' +
            encodeURIComponent(hash)
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                const play = result.data && (result.data.play_url || result.data.backup_url)
                if (play) {
                    callback(null, { url: play })
                } else {
                    callback({ message: '获取播放链接失败: ' + (result.error || ('HTTP ' + resp.statusCode)) }, null)
                }
            } catch (e) {
                callback({ message: '播放接口返回非 JSON: HTTP ' + resp.statusCode }, null)
            }
        })
    }

    function handleMusicUrl(info, callback) {
        requestUrl(info.songmid, callback)
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        const url = 'https://www.kugou.com/yy/index.php?r=play/getdata&hash=' +
            encodeURIComponent(info.songmid)
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                const lrc = (result.data && result.data.lyrics) || ''
                callback(null, { lyric: lrc, tlyric: '' })
            } catch (e) {
                callback(null, { lyric: '', tlyric: '' })
            }
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        const url = 'https://www.kugou.com/yy/index.php?r=play/getdata&hash=' +
            encodeURIComponent(info.songmid)
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                const pic = (result.data && (result.data.img || result.data.album_img)) || ''
                callback(null, { url: pic })
            } catch (e) {
                callback(null, { url: '' })
            }
        })
    }

    // ==================== 推荐 (热门关键词搜索兜底) ====================
    function handleBoard(info, callback) {
        const picks = [HOT[0], HOT[2], HOT[4]]
        let merged = []
        let done = 0
        picks.forEach(function(kw) {
            handleSearch({ keyword: kw, page: 1 }, function(err, data) {
                done++
                if (!err && data && data.list) {
                    merged = merged.concat(data.list)
                }
                if (done === picks.length) {
                    // 去重
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
