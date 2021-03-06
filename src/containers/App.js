'use strict'

import React, { Component } from 'react'
import { StatusBar } from 'react-native'
import { Provider } from 'react-redux'

import Routes from 'src/containers/Routes'
import store from 'src/store'

import { appStart } from 'src/actions/app'

export default class App extends Component {
  componentWillMount() {
    StatusBar.setHidden(true, false)
  }

  componentDidMount () {
    store.dispatch(appStart())
  }

  render () {
    return (
      <Provider store={store}>
        <Routes />
      </Provider>
    )
  }
}
