// QQ音乐源脚本
//   搜索:   https://c.y.qq.com/soso/fcgi-bin/client_search_cp (new_json=1, JSON)
//   榜单:   https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg (topid=26 热歌榜)
//   播放:   https://u.y.qq.com/cgi-bin/music.fcg 换取 vkey (真机通常可用, 部分歌曲需鉴权)
//   歌词:   https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg
;(function() {
    const source = 'tx'

    lx.send(EVENT_NAMES.inited, {
        sources: ['tx'],
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
        'Referer': 'https://y.qq.com/'
    }

    function cleanText(s) {
        return (s || '').replace(/&nbsp;/g, ' ').replace(/<[^>]+>/g, '').trim()
    }

    function parseBody(body) {
        if (!body) return null
        try { return JSON.parse(body) } catch (e) {}
        return null
    }

    function picOf(albummid) {
        return albummid ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + albummid + '.jpg' : ''
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1
        const url = 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?ct=24&qqmusic_ver=1298' +
            '&new_json=1&remoteplace=txt.yqq.top&searchid=&t=0&aggr=1&cr=1&catZhida=0&lossless=0' +
            '&flag_qc=0&p=' + page + '&n=30&w=' + encodeURIComponent(keyword) +
            '&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8' +
            '&notice=0&platform=yqq.json&needNewCode=0'

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            const result = parseBody(resp.body)
            if (!result || !result.data || !result.data.song || !result.data.song.list) {
                callback({ message: '搜索接口返回异常 (HTTP ' + resp.statusCode + ')' }, null)
                return
            }
            const list = result.data.song.list.map(function(item) {
                const singers = (item.singer || []).map(function(s) { return s.name }).join('/')
                return {
                    songmid: item.songmid || '',
                    name: cleanText(item.songname) || '未知歌曲',
                    singer: singers || '未知歌手',
                    albumName: cleanText(item.albumname),
                    albumId: item.albummid || '',
                    img: picOf(item.albummid),
                    interval: parseInt(item.interval || '0', 10) || 0,
                    quality: '320k'
                }
            }).filter(function(item) { return item.songmid && item.name })
            callback(null, { list: list, total: list.length })
        })
    }

    // ==================== 播放链接 ====================
    function filenameFor(songmid, quality) {
        if (quality === 'flac') return 'F000' + songmid + '.flac'
        if (quality === '128k') return 'M500' + songmid + '.mp3'
        return 'M800' + songmid + '.mp3' // 320k
    }

    function handleMusicUrl(info, callback) {
        const songmid = info.songmid || ''
        const quality = info.quality || '320k'
        const filename = filenameFor(songmid, quality)
        const guid = String(Math.floor(Math.random() * 1e10))
        const url = 'https://u.y.qq.com/cgi-bin/music.fcg?format=json&platform=ypc&cid=205361747' +
            '&uin=0&songmid=' + songmid + '&filename=' + filename + '&guid=' + guid

        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                const item = result.data && result.data.items && result.data.items[0]
                const vkey = item && item.vkey
                if (vkey) {
                    const playUrl = 'https://dl.stream.qqmusic.qq.com/' + filename +
                        '?vkey=' + vkey + '&guid=' + guid + '&fromtag=66'
                    callback(null, { url: playUrl })
                } else {
                    callback({ message: '获取播放链接失败(可能需鉴权): ' + (item ? item.subcode : ('HTTP ' + resp.statusCode)) }, null)
                }
            } catch (e) {
                callback({ message: '播放接口返回非 JSON: HTTP ' + resp.statusCode }, null)
            }
        })
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        const songmid = info.songmid || ''
        const url = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=' + songmid +
            '&format=json&nobase64=1&g_tk=5381&loginUin=0&hostUin=0&platform=yqq.json&needNewCode=0'
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                const lrc = (result.lyric || '').replace(/<[^>]+>/g, '')
                const tlrc = (result.trans || '').replace(/<[^>]+>/g, '')
                callback(null, { lyric: lrc, tlyric: tlrc })
            } catch (e) {
                callback(null, { lyric: '', tlyric: '' })
            }
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        // info.songmid 实际传入的是 albummid (见搜索映射), 这里兼容
        const albummid = info.songmid || ''
        callback(null, { url: picOf(albummid) })
    }

    // ==================== 排行榜 (热歌榜 topid=26) ====================
    function handleBoard(info, callback) {
        const url = 'https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?type=top&topid=26' +
            '&song_begin=0&song_num=30&format=json&inCharset=utf8&outCharset=utf-8&notice=0' +
            '&platform=h5&needNewCode=1&uin=0'
        lx.request(url, { method: 'GET', headers: HEADERS, timeout: 15 }, function(err, resp) {
            if (err) { callback(err, null); return }
            const result = parseBody(resp.body)
            if (!result || !result.songlist) {
                callback({ message: '榜单接口返回异常' }, null)
                return
            }
            const list = result.songlist.map(function(item) {
                const d = item.data || {}
                const singers = (d.singer || []).map(function(s) { return s.name }).join('/')
                return {
                    songmid: d.songmid || '',
                    name: cleanText(d.songname) || '未知歌曲',
                    singer: singers || '未知歌手',
                    albumName: cleanText(d.albumname),
                    albumId: d.albummid || '',
                    img: picOf(d.albummid),
                    interval: parseInt(d.interval || '0', 10) || 0,
                    quality: '320k'
                }
            }).filter(function(item) { return item.songmid && item.name })
            callback(null, { list: list, total: list.length })
        })
    }
})()
